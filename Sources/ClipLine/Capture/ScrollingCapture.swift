import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Scrolling Long Screenshot Stitcher (Deterministic Overlap Detection)

enum ScrollingStitchResult: Equatable {
    case unchanged
    case appended(addedPixels: Int, totalPixelHeight: Int)
    case skippedNoOverlap
    case reachedMaxHeight
}

enum ScrollingDirectionHint: Equatable {
    case unknown
    case downward
    case upward
}

struct ScrollingImageStitcher {
    let scaleFactor: CGFloat
    let maxTotalPixelHeight: Int
    private(set) var accumulatedCGImage: CGImage
    private(set) var frameCount: Int = 1
    private var accumulatedRowSignatures: [RowSignature]
    private var lastEvaluatedFrameSignatures: [RowSignature]? = nil
    private var lastEvaluatedTerminalResult: ScrollingStitchResult? = nil
    private var lastEvaluatedDirectionHint: ScrollingDirectionHint = .unknown
    private var lastEvaluatedDirectionalPair: (
        rows: [RowSignature],
        downEval: DirectionalEvaluation,
        upEval: DirectionalEvaluation,
        hasDownCandidates: Bool,
        hasUpCandidates: Bool
    )? = nil
    private var stickyTopHeaderRowCount: Int? = nil

    // Trim top and bottom 8% when matching to ignore fixed sticky navbars / bottom status bars
    static let stickyHeaderTrimRatio: Double = 0.08
    static let stickyFooterTrimRatio: Double = 0.08
    // Ignore left and right 10% when computing row signatures so scrollbar thumb movement does not skew matching
    static let horizontalMarginTrimRatio: Double = 0.10

    init(initialFrame: CGImage, scaleFactor: CGFloat, maxTotalPixelHeight: Int = 24_000) {
        self.accumulatedCGImage = initialFrame
        self.scaleFactor = max(1.0, scaleFactor)
        self.maxTotalPixelHeight = max(initialFrame.height * 2, maxTotalPixelHeight)
        self.accumulatedRowSignatures = Self.extractRowSignatures(from: initialFrame)
    }

    var currentPointSize: NSSize {
        NSSize(
            width: CGFloat(accumulatedCGImage.width) / scaleFactor,
            height: CGFloat(accumulatedCGImage.height) / scaleFactor
        )
    }

    var currentNSImage: NSImage {
        let size = currentPointSize
        let rep = NSBitmapImageRep(cgImage: accumulatedCGImage)
        rep.size = size
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    mutating func appendFrame(
        _ nextFrame: CGImage,
        directionHint: ScrollingDirectionHint = .unknown
    ) -> ScrollingStitchResult {
        guard nextFrame.width == accumulatedCGImage.width,
              nextFrame.height >= 32,
              accumulatedCGImage.height >= 32 else {
            return .skippedNoOverlap
        }
        if accumulatedCGImage.height >= maxTotalPixelHeight {
            return .reachedMaxHeight
        }

        let frameH = nextFrame.height
        let accH = accumulatedCGImage.height
        let compareH = min(frameH, accH)

        if accumulatedRowSignatures.count != accH {
            accumulatedRowSignatures = Self.extractRowSignatures(from: accumulatedCGImage)
        }
        let nextRows = Self.extractRowSignatures(from: nextFrame)
        guard accumulatedRowSignatures.count == accH, nextRows.count == frameH else {
            return .skippedNoOverlap
        }

        let prevBottomOffset = accH - compareH
        let topMargin = max(2, min(compareH / 4, Int((Double(frameH) * Self.stickyHeaderTrimRatio).rounded())))
        let bottomMargin = max(2, min(compareH / 4, Int((Double(frameH) * Self.stickyFooterTrimRatio).rounded())))

        // 0. Fast cached short-circuit ONLY when the exact same signature frame AND directionHint are re-submitted
        if let lastRows = lastEvaluatedFrameSignatures,
           let lastResult = lastEvaluatedTerminalResult,
           lastEvaluatedDirectionHint == directionHint,
           Self.signaturesExactlyEqual(lastRows, nextRows) {
            return lastResult
        }

        let cachedSameFrame = lastEvaluatedDirectionalPair.map { Self.signaturesExactlyEqual($0.rows, nextRows) } ?? false

        if !cachedSameFrame {
            // 1. Fast check for zero scroll (identical interior content at the bottom of the accumulated strip, verified on every interior row)
            let interiorCompareLen = max(0, compareH - topMargin - bottomMargin)
            let zeroShiftError = Self.exactMeanAbsoluteDifference(
                accumulatedRows: accumulatedRowSignatures,
                accStart: prevBottomOffset + topMargin,
                nextRows: nextRows,
                nextStart: topMargin,
                length: interiorCompareLen,
                earlyAbortThreshold: 1.8
            )
            if zeroShiftError < 1.8 {
                return cacheTerminalResult(.unchanged, directionHint: directionHint, for: nextRows)
            }

            // 2. Check if this viewport was already captured earlier in the accumulated image
            // (handles scrolling up and scrolling back down through already-stitched content without duplicates)
            if Self.isInteriorAlreadyCaptured(
                accumulatedRows: accumulatedRowSignatures,
                nextRows: nextRows,
                topMargin: topMargin,
                bottomMargin: bottomMargin
            ) {
                return cacheTerminalResult(.unchanged, directionHint: directionHint, for: nextRows)
            }
        }

        // 3. Search scroll shift `s` using mathematically sound lower-bound pruning:
        //    - Collect full downward and upward candidates once per distinct frame and cache both complete evaluations.
        //    - Any unambiguous match (`bestScore <= 11.5 && !isAmbiguous`) in the opposite direction is treated as a
        //      conflict in ALL modes (`.unknown`, `.downward`, `.upward`) so a stale wheel hint followed by a scrollbar/PageUp
        //      reversal never stitches on the wrong end; directional hints only disambiguate when the opposite direction's
        //      candidates are absent or internally ambiguous (e.g. multiple line-grid peaks).
        let minShift = max(4, Int(scaleFactor * 2))
        let maxShift = max(minShift, Int(Double(compareH) * 0.90))
        let minOverlapRows = max(12, Int(Double(compareH) * 0.06))

        let downEval: DirectionalEvaluation
        let upEval: DirectionalEvaluation
        let hasDownCandidates: Bool
        let hasUpCandidates: Bool
        if let cachedPair = lastEvaluatedDirectionalPair,
           Self.signaturesExactlyEqual(cachedPair.rows, nextRows) {
            downEval = cachedPair.downEval
            upEval = cachedPair.upEval
            hasDownCandidates = cachedPair.hasDownCandidates
            hasUpCandidates = cachedPair.hasUpCandidates
        } else {
            let downCandidates = Self.collectDirectionalCandidates(
                accumulatedRows: accumulatedRowSignatures,
                nextRows: nextRows,
                isDownward: true,
                prevBottomOffset: prevBottomOffset,
                topMargin: topMargin,
                bottomMargin: bottomMargin,
                compareH: compareH,
                minShift: minShift,
                maxShift: maxShift,
                minOverlapRows: minOverlapRows
            )
            let upCandidates = Self.collectDirectionalCandidates(
                accumulatedRows: accumulatedRowSignatures,
                nextRows: nextRows,
                isDownward: false,
                prevBottomOffset: prevBottomOffset,
                topMargin: topMargin,
                bottomMargin: bottomMargin,
                compareH: compareH,
                minShift: minShift,
                maxShift: maxShift,
                minOverlapRows: minOverlapRows
            )
            downEval = Self.evaluateDirectionalMatch(
                candidates: downCandidates,
                rowsForPeriodicCheck: nextRows,
                minShift: minShift
            )
            upEval = Self.evaluateDirectionalMatch(
                candidates: upCandidates,
                rowsForPeriodicCheck: accumulatedRowSignatures,
                minShift: minShift
            )
            hasDownCandidates = !downCandidates.isEmpty
            hasUpCandidates = !upCandidates.isEmpty
            lastEvaluatedDirectionalPair = (
                rows: nextRows,
                downEval: downEval,
                upEval: upEval,
                hasDownCandidates: hasDownCandidates,
                hasUpCandidates: hasUpCandidates
            )
        }

        let downUnambiguous = downEval.bestShift != nil && downEval.bestScore <= 11.5 && !downEval.isAmbiguous
        let upUnambiguous = upEval.bestShift != nil && upEval.bestScore <= 11.5 && !upEval.isAmbiguous

        let downValid: Bool
        let upValid: Bool
        switch directionHint {
        case .unknown:
            let hasCrossDirectionConflict = hasDownCandidates && hasUpCandidates
            downValid = downUnambiguous && !hasCrossDirectionConflict
            upValid = upUnambiguous && !hasCrossDirectionConflict
        case .downward:
            downValid = downUnambiguous && !upUnambiguous
            upValid = false
        case .upward:
            downValid = false
            upValid = upUnambiguous && !downUnambiguous
        }
        guard downValid || upValid else {
            return cacheTerminalResult(.skippedNoOverlap, directionHint: directionHint, for: nextRows)
        }

        let prependUpward = upValid && (!downValid || upEval.bestScore < downEval.bestScore)
        let shift = prependUpward ? upEval.bestShift! : downEval.bestShift!
        let availableNewHeight = min(shift, maxTotalPixelHeight - accH)
        guard availableNewHeight > 0 else {
            return cacheTerminalResult(.reachedMaxHeight, directionHint: directionHint, for: nextRows)
        }

        // Update tracked stationary top-header prefix length across frames:
        // Only rows in `0..<topMargin` that remain stationary (`rowMAD <= 4.0`) across EVERY accepted scroll frame
        // and do NOT match the shifted document row in `nextRows` can be part of a real sticky header.
        let currentFrameStickyPrefix = Self.stationaryStickyPrefixCount(
            accumulatedRows: accumulatedRowSignatures,
            nextRows: nextRows,
            topMargin: topMargin,
            shift: shift,
            isUpward: prependUpward
        )
        if let existingPrefix = stickyTopHeaderRowCount {
            stickyTopHeaderRowCount = min(existingPrefix, currentFrameStickyPrefix)
        } else {
            stickyTopHeaderRowCount = currentFrameStickyPrefix
        }
        let confirmedHeaderRows = stickyTopHeaderRowCount ?? 0

        if prependUpward {
            if availableNewHeight < shift && confirmedHeaderRows < 2 {
                // Without a confirmed stationary sticky header, taking `nextFrame[0..<topMargin]` plus a truncated document slice would skip rows.
                // Instead, take the contiguous slice immediately above `accumulated`'s row `topMargin`: `(shift - availableNewHeight)..<(shift + topMargin)`.
                let contiguousStart = shift - availableNewHeight
                let contiguousHeight = topMargin + availableNewHeight
                let keepStartInAcc = topMargin
                let keepHeightInAcc = accH - topMargin
                let newTotalH = contiguousHeight + keepHeightInAcc

                guard let topNewCG = nextFrame.cropping(
                    to: CGRect(x: 0, y: contiguousStart, width: nextFrame.width, height: contiguousHeight)
                ),
                      let bottomKeepCG = accumulatedCGImage.cropping(
                        to: CGRect(x: 0, y: keepStartInAcc, width: accumulatedCGImage.width, height: keepHeightInAcc)
                      ),
                      let combined = Self.verticallyCombine(top: topNewCG, bottom: bottomKeepCG, totalHeight: newTotalH) else {
                    return cacheTerminalResult(.skippedNoOverlap, directionHint: directionHint, for: nextRows)
                }

                accumulatedCGImage = combined
                accumulatedRowSignatures.removeFirst(topMargin)
                accumulatedRowSignatures.insert(
                    contentsOf: nextRows[contiguousStart..<(contiguousStart + contiguousHeight)],
                    at: 0
                )
                frameCount += 1
                lastEvaluatedDirectionalPair = nil
                _ = cacheTerminalResult(.unchanged, directionHint: directionHint, for: nextRows)
                return .appended(addedPixels: availableNewHeight, totalPixelHeight: newTotalH)
            }

            // Seamless splice across the confirmed sticky-header boundary `headerCut`:
            // When `availableNewHeight < shift`, use `headerCut = confirmedHeaderRows` (e.g. 12 rows even when `topMargin == 13`)
            // so stationary header rows `0..<headerCut` stay at the top while document rows immediately below `headerCut` remain 100% contiguous!
            let headerCut = (availableNewHeight < shift) ? min(topMargin, max(2, confirmedHeaderRows)) : topMargin
            let docStartInNext = headerCut + shift - availableNewHeight
            let keepStartInAcc = headerCut
            let keepHeightInAcc = accH - headerCut
            let newTotalH = headerCut + availableNewHeight + keepHeightInAcc

            let topNewCG: CGImage?
            if docStartInNext == headerCut {
                topNewCG = nextFrame.cropping(
                    to: CGRect(x: 0, y: 0, width: nextFrame.width, height: headerCut + availableNewHeight)
                )
            } else if let headerCG = nextFrame.cropping(
                to: CGRect(x: 0, y: 0, width: nextFrame.width, height: headerCut)
            ),
                      let docSliceCG = nextFrame.cropping(
                        to: CGRect(x: 0, y: docStartInNext, width: nextFrame.width, height: availableNewHeight)
                      ) {
                topNewCG = Self.verticallyCombine(
                    top: headerCG,
                    bottom: docSliceCG,
                    totalHeight: headerCut + availableNewHeight
                )
            } else {
                topNewCG = nil
            }

            guard let validTopNewCG = topNewCG,
                  let bottomKeepCG = accumulatedCGImage.cropping(
                    to: CGRect(x: 0, y: keepStartInAcc, width: accumulatedCGImage.width, height: keepHeightInAcc)
                  ),
                  let combined = Self.verticallyCombine(top: validTopNewCG, bottom: bottomKeepCG, totalHeight: newTotalH) else {
                return cacheTerminalResult(.skippedNoOverlap, directionHint: directionHint, for: nextRows)
            }

            accumulatedCGImage = combined
            accumulatedRowSignatures.removeFirst(headerCut)
            var prependedSignatures: [RowSignature] = []
            prependedSignatures.reserveCapacity(headerCut + availableNewHeight)
            prependedSignatures.append(contentsOf: nextRows[0..<headerCut])
            prependedSignatures.append(contentsOf: nextRows[docStartInNext..<(docStartInNext + availableNewHeight)])
            accumulatedRowSignatures.insert(contentsOf: prependedSignatures, at: 0)
            frameCount += 1
            lastEvaluatedDirectionalPair = nil
            _ = cacheTerminalResult(.unchanged, directionHint: directionHint, for: nextRows)
            return .appended(addedPixels: availableNewHeight, totalPixelHeight: newTotalH)
        } else {
            // Seamless splice across the bottom sticky-footer boundary:
            // Replace the bottom `bottomMargin` rows of `accumulatedCGImage` and append `availableNewHeight + bottomMargin`
            // rows from `nextFrame` starting at `frameH - bottomMargin - shift`, so any sticky bottom bar stays only at the very bottom!
            let spliceCutInAcc = accH - bottomMargin
            let sliceStartInNext = frameH - bottomMargin - shift
            let sliceHeightInNext = availableNewHeight + bottomMargin
            let newTotalH = spliceCutInAcc + sliceHeightInNext

            guard let topKeepCG = accumulatedCGImage.cropping(
                to: CGRect(x: 0, y: 0, width: accumulatedCGImage.width, height: spliceCutInAcc)
            ),
                  let bottomNewCG = nextFrame.cropping(
                    to: CGRect(x: 0, y: sliceStartInNext, width: nextFrame.width, height: sliceHeightInNext)
                  ),
                  let combined = Self.verticallyCombine(top: topKeepCG, bottom: bottomNewCG, totalHeight: newTotalH) else {
                return cacheTerminalResult(.skippedNoOverlap, directionHint: directionHint, for: nextRows)
            }

            accumulatedCGImage = combined
            accumulatedRowSignatures.removeLast(bottomMargin)
            accumulatedRowSignatures.append(
                contentsOf: nextRows[sliceStartInNext..<(sliceStartInNext + sliceHeightInNext)]
            )
            frameCount += 1
            lastEvaluatedDirectionalPair = nil
            _ = cacheTerminalResult(.unchanged, directionHint: directionHint, for: nextRows)
            return .appended(addedPixels: availableNewHeight, totalPixelHeight: newTotalH)
        }
    }

    private mutating func cacheTerminalResult(
        _ result: ScrollingStitchResult,
        directionHint: ScrollingDirectionHint,
        for rows: [RowSignature]
    ) -> ScrollingStitchResult {
        lastEvaluatedFrameSignatures = rows
        lastEvaluatedTerminalResult = result
        lastEvaluatedDirectionHint = directionHint
        return result
    }

    private static func signaturesExactlyEqual(_ lhs: [RowSignature], _ rhs: [RowSignature]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for i in 0..<lhs.count {
            if !lhs[i].hasIdenticalBytes(to: rhs[i]) {
                return false
            }
        }
        return true
    }

    private static func stationaryStickyPrefixCount(
        accumulatedRows: [RowSignature],
        nextRows: [RowSignature],
        topMargin: Int,
        shift: Int,
        isUpward: Bool
    ) -> Int {
        let limit = min(topMargin, min(accumulatedRows.count, nextRows.count))
        guard limit >= 2 else { return 0 }
        let samplesPerRow = sampleColumns * 3
        let maxStationaryRowDiff = 4 * samplesPerRow
        let minMovedRowDiff = 6 * samplesPerRow
        var count = 0
        for y in 0..<limit {
            let stationaryDiff = rowL1Diff(accumulatedRows[y], nextRows[y])
            guard stationaryDiff <= maxStationaryRowDiff else { break }
            // Verify row `y` did not simply scroll with the document content
            if isUpward, y + shift < nextRows.count {
                let movedDiff = rowL1Diff(accumulatedRows[y], nextRows[y + shift])
                if movedDiff <= minMovedRowDiff {
                    break
                }
            } else if !isUpward, y + shift < accumulatedRows.count {
                let movedDiff = rowL1Diff(accumulatedRows[y + shift], nextRows[y])
                if movedDiff <= minMovedRowDiff {
                    break
                }
            }
            count += 1
        }
        return count >= 2 ? count : 0
    }

    // MARK: - Horizontal Row Signature Sampling

    static let sampleColumns = 32

    struct RowSignature {
        var samples: [UInt8] // sampleColumns * 3 (R, G, B)
        var channelSum: Int // exact sum of all 96 RGB channels (0...24480)
        var rgbSums: (Int, Int, Int) // exact sums of R, G, and B channels across the 32 sampled columns
        var bandSums: (Int, Int, Int, Int) // exact sums of 4 horizontal column bands (24 channels each)
        var packedWords: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) // 96 bytes packed as 12 UInt64 words for fast exact equality checks

        @inline(__always)
        func hasIdenticalBytes(to other: RowSignature) -> Bool {
            packedWords.0 == other.packedWords.0
                && packedWords.1 == other.packedWords.1
                && packedWords.2 == other.packedWords.2
                && packedWords.3 == other.packedWords.3
                && packedWords.4 == other.packedWords.4
                && packedWords.5 == other.packedWords.5
                && packedWords.6 == other.packedWords.6
                && packedWords.7 == other.packedWords.7
                && packedWords.8 == other.packedWords.8
                && packedWords.9 == other.packedWords.9
                && packedWords.10 == other.packedWords.10
                && packedWords.11 == other.packedWords.11
        }
    }

    private struct DirectionalCandidate {
        let shift: Int
        let score: Double
        let overlapStart: Int
        let overlapEnd: Int
    }

    private struct DirectionalEvaluation {
        let bestShift: Int?
        let bestScore: Double
        let isAmbiguous: Bool
    }

    @inline(__always)
    private static func rowLowerBound(_ a: RowSignature, _ b: RowSignature) -> Int {
        if a.hasIdenticalBytes(to: b) {
            return 0
        }
        let bandLB = abs(a.bandSums.0 - b.bandSums.0)
            + abs(a.bandSums.1 - b.bandSums.1)
            + abs(a.bandSums.2 - b.bandSums.2)
            + abs(a.bandSums.3 - b.bandSums.3)
        let rgbLB = abs(a.rgbSums.0 - b.rgbSums.0)
            + abs(a.rgbSums.1 - b.rgbSums.1)
            + abs(a.rgbSums.2 - b.rgbSums.2)
        return max(bandLB, rgbLB)
    }

    @inline(__always)
    private static func rowL1Diff(_ a: RowSignature, _ b: RowSignature) -> Int {
        if a.hasIdenticalBytes(to: b) {
            return 0
        }
        var diff = 0
        a.samples.withUnsafeBufferPointer { bufA in
            b.samples.withUnsafeBufferPointer { bufB in
                let count = min(bufA.count, bufB.count)
                guard let baseA = bufA.baseAddress, let baseB = bufB.baseAddress else { return }
                var i = 0
                while i + 3 < count {
                    diff += abs(Int(baseA[i]) - Int(baseB[i]))
                        + abs(Int(baseA[i + 1]) - Int(baseB[i + 1]))
                        + abs(Int(baseA[i + 2]) - Int(baseB[i + 2]))
                        + abs(Int(baseA[i + 3]) - Int(baseB[i + 3]))
                    i += 4
                }
                while i < count {
                    diff += abs(Int(baseA[i]) - Int(baseB[i]))
                    i += 1
                }
            }
        }
        return diff
    }

    private static func collectDirectionalCandidates(
        accumulatedRows: [RowSignature],
        nextRows: [RowSignature],
        isDownward: Bool,
        prevBottomOffset: Int,
        topMargin: Int,
        bottomMargin: Int,
        compareH: Int,
        minShift: Int,
        maxShift: Int,
        minOverlapRows: Int
    ) -> [DirectionalCandidate] {
        guard minShift <= maxShift else { return [] }
        var candidates: [DirectionalCandidate] = []
        let detailSourceRows = isDownward ? nextRows : accumulatedRows
        var bestScoreSoFar = 11.5
        var firstBestCandidate: DirectionalCandidate? = nil
        var foundSameDirRivalToFirstBest = false

        let maxDetailY = min(detailSourceRows.count, compareH - bottomMargin)
        let samplesPerRow = sampleColumns * 3
        var adjacentRowDiffPrefix = [Int](repeating: 0, count: max(1, maxDetailY + 1))
        var nonUniformRowPrefix = [Int](repeating: 0, count: max(1, maxDetailY + 1))
        if maxDetailY > 1 {
            for y in 1..<maxDetailY {
                let row = detailSourceRows[y]
                adjacentRowDiffPrefix[y + 1] = adjacentRowDiffPrefix[y] + rowL1Diff(detailSourceRows[y - 1], row)
                let bandMin = min(min(row.bandSums.0, row.bandSums.1), min(row.bandSums.2, row.bandSums.3))
                let bandMax = max(max(row.bandSums.0, row.bandSums.1), max(row.bandSums.2, row.bandSums.3))
                let hasHorizontalStructure = (bandMax - bandMin) >= 96
                nonUniformRowPrefix[y + 1] = nonUniformRowPrefix[y] + (hasHorizontalStructure ? 1 : 0)
            }
        }

            for s in minShift...maxShift {
            let overlapStart = topMargin
            let overlapEnd = compareH - bottomMargin - s
            let overlapLen = overlapEnd - overlapStart
            guard overlapLen >= minOverlapRows else { continue }
            let adjRows = max(1, overlapEnd - (overlapStart + 1))
            let adjDiffSum = adjacentRowDiffPrefix[overlapEnd] - adjacentRowDiffPrefix[min(overlapEnd, overlapStart + 1)]
            let nonUniformCount = nonUniformRowPrefix[overlapEnd] - nonUniformRowPrefix[overlapStart]
            let avgAdjacentRowMAD = Double(adjDiffSum) / Double(adjRows * samplesPerRow)
            guard avgAdjacentRowMAD >= 0.45 || nonUniformCount >= max(2, overlapLen / 20) else {
                continue
            }

            let accStart = isDownward ? (prevBottomOffset + overlapStart + s) : overlapStart
            let nextStart = isDownward ? overlapStart : (overlapStart + s)

            // Once we have BOTH a valid candidate AND a confirmed same-direction rival at >= 6px distance within
            // `max(1.8, firstBest.score + 1.5)` (which happens when `bestScoreSoFar <= 1.5`), any shift `s` that cannot
            // beat `bestScoreSoFar` has `firstBest` as a permanent rival and cannot change the ambiguity outcome!
            let neededThreshold: Double
            if candidates.isEmpty {
                neededThreshold = 11.5
            } else if foundSameDirRivalToFirstBest && bestScoreSoFar <= 1.5 {
                neededThreshold = max(0.0, bestScoreSoFar - 1e-6)
            } else {
                neededThreshold = min(11.5, max(1.8, bestScoreSoFar + 1.5))
            }

            let fullMad = exactMeanAbsoluteDifference(
                accumulatedRows: accumulatedRows,
                accStart: accStart,
                nextRows: nextRows,
                nextStart: nextStart,
                length: overlapLen,
                earlyAbortThreshold: neededThreshold
            )
            if fullMad <= 11.5 {
                let cand = DirectionalCandidate(
                    shift: s,
                    score: fullMad,
                    overlapStart: overlapStart,
                    overlapEnd: overlapEnd
                )
                candidates.append(cand)
                if let currentBest = firstBestCandidate {
                    if fullMad < currentBest.score {
                        let previousBest = currentBest
                        firstBestCandidate = cand
                        bestScoreSoFar = fullMad
                        let newRivalCap = max(1.8, fullMad + 1.5)
                        foundSameDirRivalToFirstBest = abs(previousBest.shift - cand.shift) >= 6 && previousBest.score <= newRivalCap
                    } else if !foundSameDirRivalToFirstBest {
                        let rivalCap = max(1.8, currentBest.score + 1.5)
                        if abs(cand.shift - currentBest.shift) >= 6 && fullMad <= rivalCap {
                            foundSameDirRivalToFirstBest = true
                        }
                    }
                } else {
                    firstBestCandidate = cand
                    bestScoreSoFar = fullMad
                }
            }
        }
        candidates.sort { $0.score < $1.score }
        return candidates
    }

    private static func evaluateDirectionalMatch(
        candidates: [DirectionalCandidate],
        rowsForPeriodicCheck: [RowSignature],
        minShift: Int
    ) -> DirectionalEvaluation {
        guard let first = candidates.first else {
            return DirectionalEvaluation(bestShift: nil, bestScore: .greatestFiniteMagnitude, isAmbiguous: false)
        }
        // Note: because `candidates` is sorted ascending by `score`, if another candidate at >= 6px distance
        // already lies within `rivalThreshold` of `first`, or if `first` itself is periodic (making `first`
        // a rival to any higher-scoring non-periodic candidate >= 6px away), no unambiguous match can exist.
        let rivalThreshold = max(1.8, first.score + 1.5)
        let sameDirRival = candidates.contains { abs($0.shift - first.shift) >= 6 && $0.score <= rivalThreshold }
        if sameDirRival {
            return DirectionalEvaluation(bestShift: first.shift, bestScore: first.score, isAmbiguous: true)
        }
        if overlapHasPeriodicSelfMatch(
            rows: rowsForPeriodicCheck,
            startY: first.overlapStart,
            endY: first.overlapEnd,
            minShift: minShift
        ) {
            return DirectionalEvaluation(bestShift: nil, bestScore: .greatestFiniteMagnitude, isAmbiguous: true)
        }
        return DirectionalEvaluation(bestShift: first.shift, bestScore: first.score, isAmbiguous: false)
    }

    static func extractRowSignatures(from cgImage: CGImage) -> [RowSignature] {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return [] }

        // Render into a compact width=64, height=h RGB buffer for fast deterministic row comparison
        let targetW = 64
        let bytesPerRow = targetW * 4
        var buffer = [UInt8](repeating: 0, count: h * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer,
            width: targetW,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: h))

        let xStart = max(0, Int((Double(targetW) * horizontalMarginTrimRatio).rounded()))
        let xEnd = min(targetW - 1, Int((Double(targetW) * (1.0 - horizontalMarginTrimRatio)).rounded()))
        let span = max(1, xEnd - xStart)

        var cols: [Int] = []
        cols.reserveCapacity(sampleColumns)
        for i in 0..<sampleColumns {
            let x = xStart + (i * span) / max(1, sampleColumns - 1)
            cols.append(min(targetW - 1, max(0, x)))
        }

        // Note: In CGContext raw data, row 0 in memory is the TOP row of the image (y = 0 in CGImage coordinates).
        var rows: [RowSignature] = []
        rows.reserveCapacity(h)
        let channelCount = sampleColumns * 3
        for row in 0..<h {
            let rowBase = row * bytesPerRow
            var rgb: [UInt8] = []
            rgb.reserveCapacity(channelCount)
            var sum = 0
            var rSum = 0
            var gSum = 0
            var bSum = 0
            var b0 = 0
            var b1 = 0
            var b2 = 0
            var b3 = 0
            for (colIdx, col) in cols.enumerated() {
                let px = rowBase + col * 4
                let r = buffer[px]
                let g = buffer[px + 1]
                let b = buffer[px + 2]
                rgb.append(r)
                rgb.append(g)
                rgb.append(b)
                let ri = Int(r)
                let gi = Int(g)
                let bi = Int(b)
                let pixelSum = ri + gi + bi
                sum += pixelSum
                rSum += ri
                gSum += gi
                bSum += bi
                switch colIdx >> 3 {
                case 0: b0 += pixelSum
                case 1: b1 += pixelSum
                case 2: b2 += pixelSum
                default: b3 += pixelSum
                }
            }
            let packed: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = rgb.withUnsafeBytes { raw in
                guard raw.count >= 96, let base = raw.baseAddress else {
                    return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                }
                return (
                    base.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 24, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 32, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 40, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 48, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 56, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 64, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 72, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 80, as: UInt64.self),
                    base.loadUnaligned(fromByteOffset: 88, as: UInt64.self)
                )
            }
            rows.append(
                RowSignature(
                    samples: rgb,
                    channelSum: sum,
                    rgbSums: (rSum, gSum, bSum),
                    bandSums: (b0, b1, b2, b3),
                    packedWords: packed
                )
            )
        }
        return rows
    }

    private static func isInteriorAlreadyCaptured(
        accumulatedRows: [RowSignature],
        nextRows: [RowSignature],
        topMargin: Int,
        bottomMargin: Int
    ) -> Bool {
        let interiorLen = nextRows.count - topMargin - bottomMargin
        guard interiorLen >= 12, accumulatedRows.count >= interiorLen + topMargin + bottomMargin else {
            return false
        }
        let maxOffset = accumulatedRows.count - bottomMargin - interiorLen
        guard maxOffset >= topMargin else { return false }

        let threshold = 6.0
        let samplesPerRow = sampleColumns * 3
        let maxAllowedTotal = Int((threshold * Double(interiorLen * samplesPerRow)).rounded(.up))

        // Build 1D prefix sums of `channelSum` over `accumulatedRows` so any alignment offset whose
        // window lower bound exceeds `maxAllowedTotal` is eliminated in O(1) without missing any valid match:
        // `|sumA - sumB| <= L1(A, B)`.
        var accPrefixSum = [Int](repeating: 0, count: accumulatedRows.count + 1)
        for i in 0..<accumulatedRows.count {
            accPrefixSum[i + 1] = accPrefixSum[i] + accumulatedRows[i].channelSum
        }
        var nextInteriorSum = 0
        for dy in 0..<interiorLen {
            nextInteriorSum += nextRows[topMargin + dy].channelSum
        }

        // Sample 12 evenly distributed probe rows across `0..<interiorLen`.
        // Reject when the exact probe L1 sum exceeds `maxAllowedTotal` (a strict mathematical lower bound since
        // every unsampled row has non-negative L1 difference), sort surviving offsets ascending by `probeDiff`
        // so genuine replays (`probeDiff ~= 0`) and same-probe decoys are verified first, and cap full-window
        // exact verification to the top 64 lowest-`probeDiff` candidates so large viewports (`maxAllowedTotal` >> 12-row max)
        // never run 20,000+ full-window scans on the main thread.
        let probeCount = min(interiorLen, 12)
        var probeOffsets: [Int] = []
        probeOffsets.reserveCapacity(probeCount)
        for i in 0..<probeCount {
            let dy = (i * (interiorLen - 1)) / max(1, probeCount - 1)
            if probeOffsets.last != dy {
                probeOffsets.append(dy)
            }
        }
        let d0 = probeOffsets[0]
        let dMid = probeOffsets[probeOffsets.count / 2]
        let dLast = probeOffsets[probeOffsets.count - 1]
        let t0 = nextRows[topMargin + d0]
        let tMid = nextRows[topMargin + dMid]
        let tLast = nextRows[topMargin + dLast]
        let maxThreeProbeAllowed = maxAllowedTotal
        let maxAllProbeAllowed = maxAllowedTotal

        let isLowContrastBalanced: Bool = {
            guard interiorLen >= 512 else { return false }
            let checkRows = min(8, interiorLen)
            for i in 0..<checkRows {
                if rowLowerBound(accumulatedRows[topMargin + i], nextRows[topMargin + i]) != 0 {
                    return false
                }
            }
            return true
        }()
        let perProbeTightDiff = samplesPerRow * 7

        var candidates: [(offset: Int, probeDiff: Int)] = []
        for offset in topMargin...maxOffset {
            let accWindowSum = accPrefixSum[offset + interiorLen] - accPrefixSum[offset]
            let windowSumDiff = abs(accWindowSum - nextInteriorSum)
            if windowSumDiff > maxAllowedTotal {
                continue
            }

            let d0Diff = rowL1Diff(accumulatedRows[offset + d0], t0)
            let dMidDiff = rowL1Diff(accumulatedRows[offset + dMid], tMid)
            let dLastDiff = rowL1Diff(accumulatedRows[offset + dLast], tLast)
            let quickL1 = d0Diff + dMidDiff + dLastDiff
            if quickL1 > maxThreeProbeAllowed {
                continue
            }

            var probeDiff = quickL1
            var tightProbeMatches = (d0Diff <= perProbeTightDiff ? 1 : 0)
                + (dMidDiff <= perProbeTightDiff ? 1 : 0)
                + (dLastDiff <= perProbeTightDiff ? 1 : 0)
            var exceeded = false
            for dy in probeOffsets where dy != d0 && dy != dMid && dy != dLast {
                let rDiff = rowL1Diff(accumulatedRows[offset + dy], nextRows[topMargin + dy])
                probeDiff += rDiff
                if rDiff <= perProbeTightDiff {
                    tightProbeMatches += 1
                }
                if probeDiff > maxAllProbeAllowed {
                    exceeded = true
                    break
                }
            }
            if isLowContrastBalanced && tightProbeMatches < 4 {
                continue
            }
            if !exceeded {
                candidates.append((offset: offset, probeDiff: probeDiff))
            }
        }
        guard !candidates.isEmpty else { return false }
        candidates.sort { $0.probeDiff < $1.probeDiff }

        for cand in candidates.prefix(64) {
            if exactMeanAbsoluteDifference(
                accumulatedRows: accumulatedRows,
                accStart: cand.offset,
                nextRows: nextRows,
                nextStart: topMargin,
                length: interiorLen,
                earlyAbortThreshold: threshold
            ) <= threshold {
                return true
            }
        }
        return false
    }

    // Exact 2-stage MAD with mathematical lower-bound pruning:
    // Stage 1 accumulates the row lower bound across all `length` rows (`rowLB <= exactL1`).
    // If `rowLB > maxAllowedTotal`, `exactL1` is guaranteed to exceed `maxAllowedTotal`, so we abort in ~6 integer ops/row!
    // Stage 2 checks a 16-row strided sample first (substituting `exact - lb` into `runningLowerBound` so it remains an
    // exact mathematical lower bound!) before scanning the remaining rows, aborting the instant `runningLowerBound > maxAllowedTotal`.
    private static func exactMeanAbsoluteDifference(
        accumulatedRows: [RowSignature],
        accStart: Int,
        nextRows: [RowSignature],
        nextStart: Int,
        length: Int,
        earlyAbortThreshold: Double
    ) -> Double {
        guard length > 0 else { return .greatestFiniteMagnitude }
        let samplesPerRow = sampleColumns * 3
        let maxAllowedTotal = Int((earlyAbortThreshold * Double(length * samplesPerRow)).rounded(.up))

        if length >= 16 {
            let a0 = 0
            let a1 = length / 3
            let a2 = (length * 2) / 3
            let a3 = length - 1
            let probeLB = rowLowerBound(accumulatedRows[accStart + a0], nextRows[nextStart + a0])
                + rowLowerBound(accumulatedRows[accStart + a1], nextRows[nextStart + a1])
                + rowLowerBound(accumulatedRows[accStart + a2], nextRows[nextStart + a2])
                + rowLowerBound(accumulatedRows[accStart + a3], nextRows[nextStart + a3])
            if probeLB > maxAllowedTotal {
                return .greatestFiniteMagnitude
            }
            if probeLB == 0 {
                // Balanced/constant row sums (`rowLowerBound == 0`): skip scanning `rowLowerBound` and accumulate
                // exact `rowL1Diff` directly in strided order, aborting as soon as `exactTotalDiff > maxAllowedTotal`.
                // On large viewports (`length >= 300`), also enforce a 6-row strided concentration gate:
                // if all 4 initial anchor rows already exceed `earlyAbortThreshold / 2`, check after 6 strided rows
                // whether `exactTotalDiff` exceeds `6 * samplesPerRow * (earlyAbortThreshold * 0.65)`.
                let d0 = rowL1Diff(accumulatedRows[accStart + a0], nextRows[nextStart + a0])
                if d0 > maxAllowedTotal { return .greatestFiniteMagnitude }
                let d1 = rowL1Diff(accumulatedRows[accStart + a1], nextRows[nextStart + a1])
                var exactTotalDiff = d0 + d1
                if exactTotalDiff > maxAllowedTotal { return .greatestFiniteMagnitude }
                let d2 = rowL1Diff(accumulatedRows[accStart + a2], nextRows[nextStart + a2])
                exactTotalDiff += d2
                if exactTotalDiff > maxAllowedTotal { return .greatestFiniteMagnitude }
                let d3 = rowL1Diff(accumulatedRows[accStart + a3], nextRows[nextStart + a3])
                exactTotalDiff += d3
                if exactTotalDiff > maxAllowedTotal { return .greatestFiniteMagnitude }

                let anchorFloor = Int((earlyAbortThreshold * Double(samplesPerRow) * 0.5).rounded(.up))
                let allAnchorsNoisy = length >= 300 && d0 > anchorFloor && d1 > anchorFloor && d2 > anchorFloor && d3 > anchorFloor
                if allAnchorsNoisy {
                    let fourRowCap = Int((earlyAbortThreshold * Double(samplesPerRow * 4) * 0.65).rounded(.up))
                    if exactTotalDiff > fourRowCap {
                        return .greatestFiniteMagnitude
                    }
                }

                var sampledRows = 4
                let eightRowCap = Int((earlyAbortThreshold * Double(samplesPerRow * 8) * 0.85).rounded(.up))
                let stride = max(2, min(16, length / 16))
                for rem in 0..<stride {
                    var sdy = rem
                    while sdy < length {
                        if sdy != a0 && sdy != a1 && sdy != a2 && sdy != a3 {
                            exactTotalDiff += rowL1Diff(accumulatedRows[accStart + sdy], nextRows[nextStart + sdy])
                            sampledRows += 1
                            if exactTotalDiff > maxAllowedTotal || (allAnchorsNoisy && sampledRows == 8 && exactTotalDiff > eightRowCap) {
                                return .greatestFiniteMagnitude
                            }
                        }
                        sdy += stride
                    }
                }
                return Double(exactTotalDiff) / Double(length * samplesPerRow)
            }
        }

        var runningLowerBound = 0
        if length >= 64 {
            let lbStride = 4
            var dy = 0
            while dy < length {
                runningLowerBound += rowLowerBound(accumulatedRows[accStart + dy], nextRows[nextStart + dy])
                if runningLowerBound > maxAllowedTotal {
                    return .greatestFiniteMagnitude
                }
                dy += lbStride
            }
            if runningLowerBound * 16 >= maxAllowedTotal {
                for rem in 1..<lbStride {
                    var rdy = rem
                    while rdy < length {
                        runningLowerBound += rowLowerBound(accumulatedRows[accStart + rdy], nextRows[nextStart + rdy])
                        if runningLowerBound > maxAllowedTotal {
                            return .greatestFiniteMagnitude
                        }
                        rdy += lbStride
                    }
                }
            } else {
                var exactTotalDiff = 0
                let stride = max(2, min(16, length / 16))
                for rem in 0..<stride {
                    var sdy = rem
                    while sdy < length {
                        exactTotalDiff += rowL1Diff(accumulatedRows[accStart + sdy], nextRows[nextStart + sdy])
                        if exactTotalDiff > maxAllowedTotal {
                            return .greatestFiniteMagnitude
                        }
                        sdy += stride
                    }
                }
                return Double(exactTotalDiff) / Double(length * samplesPerRow)
            }
        } else {
            for dy in 0..<length {
                runningLowerBound += rowLowerBound(accumulatedRows[accStart + dy], nextRows[nextStart + dy])
                if runningLowerBound > maxAllowedTotal {
                    return .greatestFiniteMagnitude
                }
            }
        }

        var exactTotalDiff = 0
        if length >= 32 {
            let stride = max(2, min(16, length / 16))
            for rem in 0..<stride {
                var dy = rem
                while dy < length {
                    let a = accumulatedRows[accStart + dy]
                    let b = nextRows[nextStart + dy]
                    let lb = rowLowerBound(a, b)
                    let exact = rowL1Diff(a, b)
                    exactTotalDiff += exact
                    runningLowerBound += (exact - lb)
                    if runningLowerBound > maxAllowedTotal {
                        return .greatestFiniteMagnitude
                    }
                    dy += stride
                }
            }
        } else {
            for dy in 0..<length {
                let a = accumulatedRows[accStart + dy]
                let b = nextRows[nextStart + dy]
                let lb = rowLowerBound(a, b)
                let exact = rowL1Diff(a, b)
                exactTotalDiff += exact
                runningLowerBound += (exact - lb)
                if runningLowerBound > maxAllowedTotal {
                    return .greatestFiniteMagnitude
                }
            }
        }
        return Double(exactTotalDiff) / Double(length * samplesPerRow)
    }

    private static func overlapHasPeriodicSelfMatch(
        rows: [RowSignature],
        startY: Int,
        endY: Int,
        minShift: Int
    ) -> Bool {
        let len = endY - startY
        let minPeriod = max(4, minShift)
        let maxPeriod = len / 2
        guard maxPeriod >= minPeriod else { return false }
        for period in minPeriod...maxPeriod {
            let subLen = len - period
            guard subLen >= 12 else { continue }
            if exactMeanAbsoluteDifference(
                accumulatedRows: rows,
                accStart: startY,
                nextRows: rows,
                nextStart: startY + period,
                length: subLen,
                earlyAbortThreshold: 2.0
            ) <= 2.0 {
                return true
            }
        }
        return false
    }

    private static func verticallyCombine(top: CGImage, bottom: CGImage, totalHeight: Int) -> CGImage? {
        let w = top.width
        guard w == bottom.width, totalHeight == top.height + bottom.height else { return nil }
        let colorSpace = top.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        // CoreGraphics context has bottom-left origin:
        // `bottom` goes at y = 0..<bottom.height, `top` goes at y = bottom.height..<totalHeight
        ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: w, height: bottom.height))
        ctx.draw(top, in: CGRect(x: 0, y: bottom.height, width: w, height: top.height))
        return ctx.makeImage()
    }
}

// MARK: - Live Scrolling Capture Session Controller (Click-Through Guide + Floating HUD)

@MainActor
final class ScrollingCaptureSessionController: ObservableObject {
    private struct ScrollDeltaSnapshot {
        let delta: CGFloat
        let lastEventAt: CFAbsoluteTime
        let generation: UInt64
    }

    let selectedScreenRect: NSRect
    let fullScreenFrame: NSRect
    let scaleFactor: CGFloat
    private let initialFullScreenCGImage: CGImage
    private var stitcher: ScrollingImageStitcher
    private let captureRegionProvider: ((NSRect) -> CGImage?)?
    private let asyncCaptureRegionProvider: ((NSRect) async -> CGImage?)?
    private var onComplete: ((CaptureSelectionResult?) -> Void)?

    @Published private(set) var previewImage: NSImage
    @Published private(set) var pointHeight: Int
    @Published private(set) var slicesCount: Int = 1
    @Published private(set) var statusWarning: String? = nil
    @Published private(set) var canMonitorGlobalKeys: Bool = AXIsProcessTrusted()

    private(set) var borderPanel: NSPanel?
    private(set) var hudPanel: NSPanel?
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var captureTimer: Timer?
    private var pendingScrollCaptureWorkItem: DispatchWorkItem?
    private var pendingScrollCaptureToken: UInt64 = 0
    private var lastSampledAt: CFAbsoluteTime = 0
    private var accumulatedScrollDeltaSinceLastSample: CGFloat = 0
    private var lastScrollEventAt: CFAbsoluteTime = 0
    private var scrollDeltaGeneration: UInt64 = 0
    private var isFinished = false
    private var isCompleting = false
    private var lastSampleFailed = false
    private var pendingSampleRequested = false
    private var pendingFinalFlushRequested = false
    private var captureTask: Task<Void, Never>?

    init(
        initialSelection: CaptureSelectionResult,
        initialCropCGImage: CGImage,
        captureRegionProvider: @escaping (NSRect) -> CGImage?
    ) {
        self.selectedScreenRect = initialSelection.selectedScreenRect
        self.fullScreenFrame = initialSelection.fullScreenFrame
        self.scaleFactor = initialSelection.scaleFactor
        self.initialFullScreenCGImage = initialSelection.fullScreenCGImage
        let stitcher = ScrollingImageStitcher(initialFrame: initialCropCGImage, scaleFactor: initialSelection.scaleFactor)
        self.stitcher = stitcher
        self.captureRegionProvider = captureRegionProvider
        self.asyncCaptureRegionProvider = nil
        self.previewImage = stitcher.currentNSImage
        self.pointHeight = Int(stitcher.currentPointSize.height.rounded())
    }

    init(
        initialSelection: CaptureSelectionResult,
        initialCropCGImage: CGImage,
        asyncCaptureRegionProvider: @escaping (NSRect) async -> CGImage?
    ) {
        self.selectedScreenRect = initialSelection.selectedScreenRect
        self.fullScreenFrame = initialSelection.fullScreenFrame
        self.scaleFactor = initialSelection.scaleFactor
        self.initialFullScreenCGImage = initialSelection.fullScreenCGImage
        let stitcher = ScrollingImageStitcher(initialFrame: initialCropCGImage, scaleFactor: initialSelection.scaleFactor)
        self.stitcher = stitcher
        self.captureRegionProvider = nil
        self.asyncCaptureRegionProvider = asyncCaptureRegionProvider
        self.previewImage = stitcher.currentNSImage
        self.pointHeight = Int(stitcher.currentPointSize.height.rounded())
    }

    var isActive: Bool {
        !isFinished
    }

    func start(onComplete: @escaping (CaptureSelectionResult?) -> Void) {
        self.onComplete = onComplete
        setupBorderPanel()
        setupHUDPanel()
        installEventMonitors()
    }

    static func directionHint(scrollingDeltaY: CGFloat, isDirectionInvertedFromDevice: Bool = true) -> ScrollingDirectionHint {
        _ = isDirectionInvertedFromDevice
        guard abs(scrollingDeltaY) > 0.01 else { return .unknown }
        // AppKit pre-applies the user's Natural/Traditional scrolling preference to `scrollingDeltaY`:
        // `scrollingDeltaY < 0` scrolls downward (revealing content below) and `scrollingDeltaY > 0` scrolls upward (revealing content above).
        return scrollingDeltaY < 0 ? .downward : .upward
    }

    func recordScrollEvent(
        scrollingDeltaY: CGFloat,
        isDirectionInvertedFromDevice: Bool = true,
        screenLocation: NSPoint? = nil,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        if let loc = screenLocation, !selectedScreenRect.contains(loc) {
            return
        }
        guard abs(scrollingDeltaY) > 0.01 else { return }
        _ = isDirectionInvertedFromDevice
        if timestamp - lastScrollEventAt > 0.45 {
            accumulatedScrollDeltaSinceLastSample = 0
            scrollDeltaGeneration &+= 1
        }
        accumulatedScrollDeltaSinceLastSample += scrollingDeltaY
        lastScrollEventAt = timestamp
    }

    func peekPendingDirectionHint(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> ScrollingDirectionHint {
        guard now - lastScrollEventAt <= 0.45 else {
            accumulatedScrollDeltaSinceLastSample = 0
            return .unknown
        }
        return Self.directionHint(scrollingDeltaY: accumulatedScrollDeltaSinceLastSample)
    }

    @discardableResult
    func sampleNextFrameIfChanged() -> Task<Void, Never>? {
        guard !isFinished, !isCompleting else { return captureTask }
        pendingScrollCaptureToken &+= 1
        pendingScrollCaptureWorkItem?.cancel()
        pendingScrollCaptureWorkItem = nil
        if let captureRegionProvider {
            processSample(captureRegionProvider(selectedScreenRect))
            return nil
        }
        pendingSampleRequested = true
        return scheduleSampleDrain()
    }

    private func processSample(_ nextCG: CGImage?, scrollDeltaSnapshot: ScrollDeltaSnapshot? = nil) {
        guard let nextCG else {
            lastSampledAt = CFAbsoluteTimeGetCurrent()
            lastSampleFailed = true
            statusWarning = L10n.scrollingCaptureCaptureFailedWarning
            return
        }
        lastSampleFailed = false
        let now = CFAbsoluteTimeGetCurrent()
        let hint: ScrollingDirectionHint
        if let scrollDeltaSnapshot {
            hint = now - scrollDeltaSnapshot.lastEventAt <= 0.45
                ? Self.directionHint(scrollingDeltaY: scrollDeltaSnapshot.delta)
                : .unknown
        } else {
            hint = peekPendingDirectionHint(now: now)
        }
        var res = stitcher.appendFrame(nextCG, directionHint: hint)
        if res == .skippedNoOverlap && hint != .unknown {
            // If a non-wheel scroll (scrollbar drag, Page Up/Down, or programmatic jump) occurred after a wheel event,
            // fall back safely to unhinted bidirectional matching before reporting overlap lost!
            res = stitcher.appendFrame(nextCG, directionHint: .unknown)
        }
        if case .appended = res {
            // Only consume accumulated wheel direction once a frame has actually been stitched (or expired > 0.45s)!
            // Preserving the wheel delta across `.unchanged` and transient intermediate `.skippedNoOverlap` samples
            // ensures the subsequent painted sample still receives the user's scroll direction hint.
            if let scrollDeltaSnapshot {
                if scrollDeltaSnapshot.generation == scrollDeltaGeneration {
                    accumulatedScrollDeltaSinceLastSample -= scrollDeltaSnapshot.delta
                    if now - lastScrollEventAt > 0.45 {
                        accumulatedScrollDeltaSinceLastSample = 0
                    }
                }
            } else {
                accumulatedScrollDeltaSinceLastSample = 0
            }
        } else if res == .reachedMaxHeight {
            accumulatedScrollDeltaSinceLastSample = 0
        }
        lastSampledAt = CFAbsoluteTimeGetCurrent()
        switch res {
        case .appended:
            statusWarning = nil
            previewImage = stitcher.currentNSImage
            pointHeight = Int(stitcher.currentPointSize.height.rounded())
            slicesCount = stitcher.frameCount
        case .unchanged:
            statusWarning = nil
        case .skippedNoOverlap:
            statusWarning = L10n.scrollingCaptureOverlapLostWarning
        case .reachedMaxHeight:
            statusWarning = nil
            if !isCompleting {
                finishCapture()
            }
        }
    }

    @discardableResult
    func finishCapture() -> Task<Void, Never>? {
        guard !isFinished, !isCompleting else { return captureTask }
        isCompleting = true
        pendingScrollCaptureToken &+= 1
        pendingScrollCaptureWorkItem?.cancel()
        pendingScrollCaptureWorkItem = nil

        if let captureRegionProvider {
            pendingSampleRequested = false
            processSample(captureRegionProvider(selectedScreenRect))
            completeCapture()
            return nil
        }
        pendingSampleRequested = false
        pendingFinalFlushRequested = true
        return scheduleSampleDrain()
    }

    private func scheduleSampleDrain() -> Task<Void, Never>? {
        guard let asyncCaptureRegionProvider else { return nil }
        if let captureTask { return captureTask }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainSamples(using: asyncCaptureRegionProvider)
        }
        captureTask = task
        return task
    }

    private func drainSamples(using provider: (NSRect) async -> CGImage?) async {
        while !isFinished {
            let isFinalFlush = pendingFinalFlushRequested
            guard isFinalFlush || pendingSampleRequested else { break }
            pendingFinalFlushRequested = false
            pendingSampleRequested = false

            // Wheel events arriving during the await belong to the next frame, not this snapshot.
            let scrollDeltaSnapshot = ScrollDeltaSnapshot(
                delta: accumulatedScrollDeltaSinceLastSample,
                lastEventAt: lastScrollEventAt,
                generation: scrollDeltaGeneration
            )
            let nextCG = await provider(selectedScreenRect)
            guard !isFinished, !Task.isCancelled else { break }
            processSample(nextCG, scrollDeltaSnapshot: scrollDeltaSnapshot)

            if isFinalFlush {
                completeCapture()
                break
            }
            if pendingFinalFlushRequested { continue }
            if pendingSampleRequested {
                let delay = 0.09 - (CFAbsoluteTimeGetCurrent() - lastSampledAt)
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        break
                    }
                }
            }
        }
        captureTask = nil
    }

    private func completeCapture() {
        guard !isFinished else { return }
        isFinished = true
        teardownMonitorsAndPanels()
        let cb = onComplete
        onComplete = nil
        if lastSampleFailed {
            cb?(nil)
            return
        }

        let finalImage = stitcher.currentNSImage
        let result = CaptureSelectionResult(
            fullScreenCGImage: initialFullScreenCGImage,
            fullScreenFrame: fullScreenFrame,
            scaleFactor: scaleFactor,
            selectedScreenRect: selectedScreenRect,
            croppedImage: finalImage,
            isScrollingCapture: true
        )
        cb?(result)
    }

    func cancelCapture() {
        guard !isFinished else { return }
        isFinished = true
        pendingSampleRequested = false
        pendingFinalFlushRequested = false
        captureTask?.cancel()
        captureTask = nil
        teardownMonitorsAndPanels()
        let cb = onComplete
        onComplete = nil
        cb?(nil)
    }

    private func setupBorderPanel() {
        let pad: CGFloat = 4
        let frame = selectedScreenRect.insetBy(dx: -pad, dy: -pad)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollingCaptureGuideFrameView())
        panel.orderFrontRegardless()
        borderPanel = panel
    }

    private func setupHUDPanel() {
        let hudWidth: CGFloat = 380
        let hudHeight: CGFloat = 176
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selectedScreenRect) }) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Place HUD to the right of the selected region if space permits, else to the left, else below/above
        var x = selectedScreenRect.maxX + 14
        var y = selectedScreenRect.midY - hudHeight / 2
        if x + hudWidth > visible.maxX - 8 {
            x = selectedScreenRect.minX - hudWidth - 14
        }
        if x < visible.minX + 8 {
            x = max(visible.minX + 8, min(visible.maxX - hudWidth - 8, selectedScreenRect.midX - hudWidth / 2))
            y = selectedScreenRect.minY - hudHeight - 12
            if y < visible.minY + 8 {
                y = min(visible.maxY - hudHeight - 8, selectedScreenRect.maxY + 12)
            }
        }
        y = max(visible.minY + 8, min(visible.maxY - hudHeight - 8, y))

        let panel = NSPanel(
            contentRect: NSRect(x: round(x), y: round(y), width: hudWidth, height: hudHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = ScrollingCaptureHUDView(
            controller: self,
            onDone: { [weak self] in self?.finishCapture() },
            onCancel: { [weak self] in self?.cancelCapture() }
        )
        panel.contentView = NSHostingView(rootView: rootView)
        panel.orderFrontRegardless()
        hudPanel = panel
    }

    private static func eventScreenLocation(_ event: NSEvent) -> NSPoint {
        if let win = event.window {
            return win.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    private func handleScrollWheelEvent(_ event: NSEvent) {
        guard !isFinished else { return }
        let loc = Self.eventScreenLocation(event)
        guard selectedScreenRect.contains(loc) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        recordScrollEvent(
            scrollingDeltaY: event.scrollingDeltaY,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice,
            screenLocation: loc,
            timestamp: now
        )
        // Throttle rather than debounce-starving continuous 60/120Hz trackpad gestures:
        // sample immediately when >= 90ms has elapsed since the last sample finished, and coalesce trailing samples with a token.
        let elapsed = now - lastSampledAt
        if elapsed >= 0.09 {
            sampleNextFrameIfChanged()
            return
        }
        if pendingScrollCaptureWorkItem == nil {
            pendingScrollCaptureToken &+= 1
            let token = pendingScrollCaptureToken
            let delay = max(0.015, 0.09 - elapsed)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, !self.isFinished, self.pendingScrollCaptureToken == token else { return }
                self.pendingScrollCaptureWorkItem = nil
                guard CFAbsoluteTimeGetCurrent() - self.lastSampledAt >= 0.09 else { return }
                self.sampleNextFrameIfChanged()
            }
            pendingScrollCaptureWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func installEventMonitors() {
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleScrollWheelEvent(event)
            }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleScrollWheelEvent(event)
            }
            return event
        }

        // Periodic fallback poll (every 0.14s) catches continuous scrolling, inertial momentum, and scrollbar/PageDown movement smoothly
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, !self.isFinished else { return }
                guard CFAbsoluteTimeGetCurrent() - self.lastSampledAt >= 0.09 else { return }
                self.sampleNextFrameIfChanged()
            }
        }

        let handleKey: (NSEvent) -> Bool = { [weak self] event in
            guard let self = self, !self.isFinished else { return false }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function])
            guard mods.isEmpty else { return false }
            if event.keyCode == 53 { // Esc
                self.cancelCapture()
                return true
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                self.finishCapture()
                return true
            }
            return false
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                _ = handleKey(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handleKey(event) {
                return nil
            }
            return event
        }
    }

    private func teardownMonitorsAndPanels() {
        pendingScrollCaptureWorkItem?.cancel()
        pendingScrollCaptureWorkItem = nil
        captureTimer?.invalidate()
        captureTimer = nil
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalScrollMonitor = nil
        localScrollMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        borderPanel = nil
        hudPanel = nil
    }
}

private struct ScrollingCaptureGuideFrameView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(
                Color(red: 0.16, green: 0.68, blue: 1.0),
                style: StrokeStyle(lineWidth: 2.2, dash: [7, 4])
            )
            .padding(2)
    }
}

private struct ScrollingCaptureHUDView: View {
    @ObservedObject var controller: ScrollingCaptureSessionController
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Live stitched thumbnail strip
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                Image(nsImage: controller.previewImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            }
            .frame(width: 74, height: 146)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.20, green: 0.86, blue: 0.48))
                        .frame(width: 8, height: 8)
                    Text(L10n.shortcutMenuScrollingCapture)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }

                Text(
                    L10n.scrollingCaptureHudStatus(
                        heightPoints: controller.pointHeight,
                        slicesCount: controller.slicesCount,
                        warning: controller.statusWarning
                    )
                )
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundColor(controller.statusWarning != nil ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !controller.canMonitorGlobalKeys && controller.statusWarning == nil {
                    Text(L10n.scrollingCapturePermissionHint)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    Button(action: onCancel) {
                        Text(L10n.scrollingCaptureCancelButton)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onDone) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(L10n.scrollingCaptureDoneButton)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 368, height: 164)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
        .padding(6)
    }
}
