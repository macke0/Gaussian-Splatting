//
//  FitBadgeView.swift
//  SpatialFit
//
//  Statusraden överst: zon, produkt, och marginalen på varje axel.
//  Alltid synlig – säljaren ska aldrig behöva leta efter siffrorna.
//

import SwiftUI

struct FitBadgeView: View {
    let fit: FitResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(Color.white.opacity(0.15))
            measurements
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(fit.zone.tint.opacity(0.55), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fit.zone.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(fit.zone.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(fit.headline)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(fit.zone.tint)
                Text(fit.message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(fit.product.name) · \(fit.product.dimensions.shortDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var measurements: some View {
        HStack(spacing: 10) {
            ForEach(fit.axes) { axis in
                AxisChip(clearance: axis)
            }
        }
    }
}

private struct AxisChip: View {
    let clearance: AxisClearance

    var body: some View {
        VStack(spacing: 2) {
            Text(clearance.axis.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(clearance.formattedClearance)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(clearance.zone.tint)
            Text("\(Units.format(clearance.requiredMM)) / \(Units.format(clearance.availableMM))")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(clearance.zone.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clearance.axis.label): \(clearance.formattedClearance) marginal")
    }
}
