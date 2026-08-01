//
//  CollisionAlertView.swift
//  SpatialFit
//
//  Krockmodalen mitt på skärmen. Den ska stoppa köpet, inte pynta det –
//  därför blockerande overlay och inte en toast.
//

import SwiftUI

struct CollisionAlertView: View {
    let fit: FitResult
    var onDismiss: () -> Void
    var onSuggestAlternative: (() -> Void)?

    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(fit.zone.tint)
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: 8) {
                    Text("⚠️ \(fit.headline)")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(fit.zone.tint)

                    Text(fit.message)
                        .font(.headline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(fit.comparison)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if !fit.intersections.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(fit.intersections) { hit in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(fit.zone.tint)
                                    .frame(width: 6, height: 6)
                                Text(hit.obstacle.kind.label)
                                    .font(.footnote.weight(.medium))
                                Spacer(minLength: 12)
                                Text("\(Units.format(hit.penetrationMM)) intrång")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(fit.zone.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }

                if let recommendation = fit.recommendation {
                    Text(recommendation)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    if let onSuggestAlternative {
                        Button(action: onSuggestAlternative) {
                            Text("Visa produkter som passar")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(fit.zone.tint)
                        .controlSize(.large)
                    }

                    Button("Visa ändå i 3D", action: onDismiss)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(fit.zone.tint.opacity(0.6), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
            .padding(24)
            .scaleEffect(appeared ? 1 : 0.9)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { appeared = true }
        }
        .transition(.opacity)
    }
}
