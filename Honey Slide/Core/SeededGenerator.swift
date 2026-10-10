//
//  SeededGenerator.swift
//  Elephant Challenge: Math Memory
//
//  A small deterministic RNG so question generation can be reproduced exactly
//  in tests. Production code uses `SystemRandomNumberGenerator`; passing a seed
//  swaps in this generator without any other change.
//

import Foundation

/// SplitMix64 — tiny, fast, and well-distributed. Deterministic for a seed.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        // A zero seed would make SplitMix64 start on a degenerate value.
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Type-erased random source so generators can hold either the system RNG or a
/// seeded one without becoming generic over their whole call graph.
public final class RandomSource {
    private var generator: any RandomNumberGenerator

    public init(seed: UInt64? = nil) {
        if let seed {
            generator = SeededGenerator(seed: seed)
        } else {
            generator = SystemRandomNumberGenerator()
        }
    }

    public func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &generator)
    }

    public func double(in range: Range<Double>) -> Double {
        Double.random(in: range, using: &generator)
    }

    public func bool() -> Bool {
        Bool.random(using: &generator)
    }

    public func element<T>(_ items: [T]) -> T? {
        items.randomElement(using: &generator)
    }

    public func shuffled<T>(_ items: [T]) -> [T] {
        items.shuffled(using: &generator)
    }

    /// Picks from an ordered easy→hard list, biased toward the hard end so the
    /// top values appear most while everything below still shows up. Weight
    /// grows linearly with position, so the bias scales with the list length
    /// and needs no per-level tuning.
    public func weightedHardPick<T>(_ items: [T]) -> T? {
        guard let last = items.last else { return nil }
        guard items.count > 1 else { return last }
        let n = items.count
        let total = n * (n + 1) / 2
        var r = int(in: 1...total)
        for i in 0..<n {
            r -= (i + 1)
            if r <= 0 { return items[i] }
        }
        return last
    }
}
