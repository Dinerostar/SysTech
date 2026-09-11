#!/usr/bin/env swift
//
//  make-app-icon.swift
//  SysTech
//
//  Draws the app icon and writes every size the macOS AppIcon set needs.
//
//  Usage: swift Scripts/make-app-icon.swift SysTech/Assets.xcassets/AppIcon.appiconset
//

import AppKit
import SwiftUI

/// The icon on Apple's 1024 pt macOS grid: an 824 pt rounded square with room
/// around it for the drop shadow.
struct AppIcon: View {
    private let gaugeCenter = CGPoint(x: 512, y: 580)
    private let gaugeRadius: CGFloat = 280
    private let startAngle = 150.0   // lower left
    private let sweep = 240.0        // clockwise over the top
    private let needleValue = 0.7

    var body: some View {
        ZStack {
            background
            gauge
        }
        .frame(width: 1024, height: 1024)
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.23, blue: 0.44),
                                          Color(red: 0.05, green: 0.07, blue: 0.16)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.02)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 4)
            )
            .frame(width: 824, height: 824)
            .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
    }

    private var gauge: some View {
        ZStack {
            // Track
            arc
                .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 64, lineCap: .round))

            // Colored scale; the gradient reaches a little past both ends so the round caps match.
            arc
                .stroke(AngularGradient(colors: [Color(red: 0.2, green: 0.85, blue: 1.0),
                                                 Color(red: 0.3, green: 0.9, blue: 0.5),
                                                 Color(red: 1.0, green: 0.85, blue: 0.2),
                                                 Color(red: 1.0, green: 0.55, blue: 0.2),
                                                 Color(red: 1.0, green: 0.3, blue: 0.35)],
                                        center: UnitPoint(x: gaugeCenter.x / 1024, y: gaugeCenter.y / 1024),
                                        startAngle: .degrees(startAngle - 8),
                                        endAngle: .degrees(startAngle + sweep + 8)),
                        style: StrokeStyle(lineWidth: 64, lineCap: .round))
                .shadow(color: Color(red: 0.2, green: 0.85, blue: 1.0).opacity(0.35), radius: 24)

            ticks
            needle
            hub
        }
    }

    private var arc: some Shape {
        ArcShape(center: gaugeCenter, radius: gaugeRadius, start: startAngle, sweep: sweep)
    }

    private var ticks: some View {
        Path { path in
            for index in 0...10 {
                let angle = Angle.degrees(startAngle + sweep * Double(index) / 10).radians
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                path.move(to: point(direction, distance: gaugeRadius - 78))
                path.addLine(to: point(direction, distance: gaugeRadius - 56))
            }
        }
        .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 9, lineCap: .round))
    }

    private var needle: some View {
        let angle = Angle.degrees(startAngle + sweep * needleValue).radians
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let tip = point(direction, distance: gaugeRadius - 40)
        let baseWidth: CGFloat = 28

        return Path { path in
            path.move(to: CGPoint(x: gaugeCenter.x + normal.x * baseWidth, y: gaugeCenter.y + normal.y * baseWidth))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: gaugeCenter.x - normal.x * baseWidth, y: gaugeCenter.y - normal.y * baseWidth))
            path.closeSubpath()
        }
        .fill(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
    }

    private var hub: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
            Circle()
                .fill(Color(red: 0.1, green: 0.13, blue: 0.27))
                .frame(width: 36, height: 36)
        }
        .position(gaugeCenter)
    }

    private func point(_ direction: CGPoint, distance: CGFloat) -> CGPoint {
        CGPoint(x: gaugeCenter.x + direction.x * distance, y: gaugeCenter.y + direction.y * distance)
    }
}

struct ArcShape: Shape {
    let center: CGPoint
    let radius: CGFloat
    let start: Double
    let sweep: Double

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addArc(center: center, radius: radius,
                        startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
        }
    }
}

// MARK: - Export

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

/// (point size, scale) pairs required by a macOS AppIcon set.
let variants: [(size: Int, scale: Int)] = [16, 32, 128, 256, 512].flatMap { [($0, 1), ($0, 2)] }

MainActor.assumeIsolated {
    for variant in variants {
        let pixels = variant.size * variant.scale
        let renderer = ImageRenderer(content: AppIcon())
        renderer.scale = CGFloat(pixels) / 1024

        guard let image = renderer.cgImage else {
            fatalError("Failed to render \(pixels) px icon")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Failed to encode \(pixels) px icon")
        }

        let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
        let url = outputDirectory.appendingPathComponent("icon_\(variant.size)x\(variant.size)\(suffix).png")
        try! png.write(to: url)
        print("Wrote \(url.lastPathComponent) (\(pixels) px)")
    }
}
