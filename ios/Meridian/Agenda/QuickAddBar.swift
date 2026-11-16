//
//  QuickAddBar.swift
//  Meridian — the bottom input line of the agenda card. OWNER: agenda/sync engineer.
//
//  One plain text field, a return hint, and a hairline. Submitting keeps the
//  caret where it was: entering three things in a row should be three returns,
//  not three taps back into the field.
//

import SwiftUI

struct QuickAddBar: View {
    @Binding var text: String
    /// Owned by AgendaPanel so its "+" button can put the caret here without
    /// this view knowing about the header.
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            TextField("添加一件事…", text: $text)
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .foregroundStyle(Palette.ink)
                .tint(Palette.ember)
                .submitLabel(.done)
                .focused(isFocused)
                .onSubmit(onSubmit)

            // A word, not a glyph or an emoji: the hint exists for the two
            // seconds before the user learns that return works.
            Text("RETURN")
                .font(Typeface.micro)
                .tracking(1.2)
                .foregroundStyle(Palette.inkQuaternary)
                .opacity(text.isEmpty ? 0.45 : 1)
                .accessibilityHidden(true)
        }
        .frame(height: 30)
        .padding(.top, Space.s)
        .overlay(alignment: .bottom) { Hairline() }
    }
}
