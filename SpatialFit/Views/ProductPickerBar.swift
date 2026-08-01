//
//  ProductPickerBar.swift
//  SpatialFit
//
//  Bottenmenyn. Varje produkt bär sin egen zonprick redan innan man väljer den –
//  säljaren ser direkt vilka artiklar som är körbara i just den här nischen.
//

import SwiftUI

struct ProductPickerBar: View {
    let verdicts: [(product: Product, zone: FitZone)]
    let selectedID: String
    var onSelect: (Product) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("VÄLJ PRODUKT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(verdicts, id: \.product.id) { entry in
                        ProductCard(product: entry.product,
                                    zone: entry.zone,
                                    isSelected: entry.product.id == selectedID)
                        .onTapGesture { onSelect(entry.product) }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

private struct ProductCard: View {
    let product: Product
    let zone: FitZone
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(zone.tint)
                    .frame(width: 8, height: 8)
                Text(zone.shortLabel)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(zone.tint)
                Spacer(minLength: 0)
            }

            Text(product.shortLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(product.dimensions.shortDescription)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? zone.tint.opacity(0.18) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? zone.tint : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.snappy(duration: 0.2), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
