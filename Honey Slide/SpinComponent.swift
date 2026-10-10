//
//  SpinComponent.swift
//  Honey Slide
//
//  Created by Jens Somers on 10/10/2026.
//

import RealityKit

/// A component that spins the entity around a given axis.
struct SpinComponent: Component {
    let spinAxis: SIMD3<Float> = [0, 1, 0]
}
