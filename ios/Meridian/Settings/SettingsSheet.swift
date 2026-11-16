//
//  SettingsSheet.swift
//  Meridian — the one door out of the clock.
//
//  Two screens' worth of options, grouped by what they change: how the time
//  looks, and where the agenda comes from. Nothing here is a "preference" for
//  its own sake — every control changes something visible on the stage.
//

import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var diagnostic: String?
    @State private var diagnosing = false

    var body: some View {
        ZStack {
            Palette.canvasLift.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    header
                    appearanceSection
                    backgroundSection
                    displaySection
                    serverSection
                    aboutSection
                }
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.xxl)
                .padding(.bottom, Space.huge)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        // The switch is a call site: RootView starts the sensor at launch and on
        // foreground, but not while this sheet is open — without this the row
        // would sit at "相机不可用" until the next app switch.
        .onChange(of: model.settings.ambientAdaptive) { _, _ in
            model.syncAmbientSensing()
        }
        // Switching source has to take effect immediately too: screen mode stops
        // the camera, precise mode starts the burst loop.
        .onChange(of: model.settings.ambientPrecise) { _, _ in
            model.syncAmbientSensing()
        }
        // A sheet dismissed by dragging down never runs the 完成 button; without
        // this the edited address would live in memory only and sync would keep
        // polling the old one until the next launch.
        .onDisappear {
            model.saveConfig()
            model.saveSettings()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("设置")
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("Meridian · 子午")
                    .font(Typeface.caption)
                    .tracking(0.6)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            Button {
                model.saveSettings()
                model.saveConfig()
                dismiss()
            } label: {
                Text("完成")
                    .font(Typeface.bodyMedium)
                    .foregroundStyle(Palette.canvas)
                    .padding(.horizontal, Space.l)
                    .frame(height: 34)
                    .background(Capsule().fill(Palette.ink))
            }
            .buttonStyle(PressableStyle())
        }
    }

    // MARK: Appearance

    /// The live preview, the six presets, then the five axes worth exposing:
    /// numeral hue, gradient, type, weight and ring. Continuous values get a
    /// slider, discrete choices keep a segment — a segmented control for a 360°
    /// hue would be a lie, and a slider for four typefaces would be unusable.
    private var appearanceSection: some View {
        section(title: "外观") {
            VStack(alignment: .leading, spacing: Space.l) {
                previewBlock

                presetRow

                VStack(spacing: 0) {
                    inkHueRow
                    gradientRow
                    gradientHueRow
                    typeRow
                    weightRow
                    ringRow
                }
                .padding(.top, Space.xs)
            }
        }
    }

    /// The preview is the control surface: every edit below lands here first, so
    /// "what will the stage look like" never has to be imagined. It renders
    /// through the same BackgroundLayer as the stage — it is not a mock-up.
    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                CapsLabel(text: "实时预览")
                Spacer(minLength: Space.m)
                Text(model.settings.skin.name)
                    .font(Typeface.micro)
                    .tracking(1.2)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }

            SkinPreview(settings: model.settings)

            Text("拖动下方控件，预览即时变化；关闭设置页时统一写入。")
                .font(Typeface.caption)
                .foregroundStyle(Palette.inkQuaternary)
        }
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                ForEach(SkinLibrary.presets, id: \.presetID) { preset in
                    presetCard(preset)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func presetCard(_ preset: ClockSkin) -> some View {
        let active = model.settings.skin.presetID == preset.presetID

        return Button {
            withAnimation(Motion.snap) { model.applyPreset(preset.presetID) }
            Haptics.commit()
        } label: {
            VStack(alignment: .leading, spacing: Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(preset.canvasColor)
                    Text("21:47")
                        .font(.system(size: 17, weight: preset.weight.value, design: preset.face.design))
                        .monospacedDigit()
                        .foregroundStyle(preset.numeralStyle)
                }
                .frame(width: 96, height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(
                            active ? Palette.ink.opacity(0.55) : Palette.hairline,
                            lineWidth: active ? 1.5 : Metrics.hairline
                        )
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(preset.accentColor)
                        .frame(width: 6, height: 6)
                        .padding(6)
                }

                Text(preset.name)
                    .font(Typeface.micro)
                    .tracking(1.2)
                    .foregroundStyle(active ? Palette.ink : Palette.inkTertiary)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .accessibilityLabel("预设 \(preset.name)")
    }

    /// The one colour control: a hue wheel collapsed to a slider. Each colour
    /// keeps its own saturation and brightness, which is what keeps the numerals
    /// from turning into a pastel wash when the hue moves. The room follows the
    /// numerals — a warm glow behind blue digits reads as two light sources.
    private var inkHueRow: some View {
        sliderRow(
            label: "数字色相",
            value: "\(Int(inkHue.wrappedValue.rounded()))°",
            tint: model.settings.skin.accentColor
        ) {
            Slider(value: inkHue, in: 0...360, step: 1)
        }
    }

    /// Reading a hue back out of a neutral colour is meaningless, so a near-grey
    /// ink borrows the accent's hue instead; without that the handle would snap
    /// back to zero on every preset whose numerals are white.
    private var inkHue: Binding<Double> {
        Binding(
            get: {
                let skin = model.settings.skin
                let ink = skin.ink.hsv
                let hue = ink.saturation < 0.02 ? skin.accent.hsv.hue : ink.hue
                return hue * 360
            },
            set: { degrees in
                var skin = model.settings.skin
                skin.ink = skin.ink.withHueSaturation(
                    hue: degrees,
                    saturation: skin.ink.hsv.saturation
                )
                skin.accent = skin.accent.withHueSaturation(
                    hue: degrees,
                    saturation: skin.accent.hsv.saturation
                )
                skin.glow = skin.glow.withHueSaturation(
                    hue: degrees,
                    saturation: skin.glow.hsv.saturation
                )
                model.settings.skin = skin
                // Bookkeeping only: persistence belongs to onDisappear, so a drag
                // does not write the state file hundreds of times.
                model.markSkinCustom()
            }
        )
    }

    /// One row for every continuous control: label and readout on one line, the
    /// slider under it. `disabled` is used by the gradient stop when the gradient
    /// is off, so the control is still visible but visibly inert.
    private func sliderRow<Control: View>(
        label: String,
        value: String,
        tint: Color,
        disabled: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(label)
                    .font(Typeface.caption)
                    .foregroundStyle(Palette.inkTertiary)
                Spacer(minLength: Space.m)
                Text(value)
                    .font(Typeface.digit(12))
                    .foregroundStyle(Palette.inkSecondary)
            }
            control()
                .tint(tint)
        }
        .padding(.vertical, Space.s)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
    }

    private var typeRow: some View {
        optionRow(label: "字体", options: DigitFace.allCases.map { ($0.label, model.settings.skin.face == $0) }) { index in
            let face = DigitFace.allCases[index]
            withAnimation(Motion.snap) {
                model.settings.skin.face = face
                model.markSkinCustom()
            }
        }
    }

    private var weightRow: some View {
        optionRow(label: "字重", options: DigitWeight.allCases.map { ($0.label, model.settings.skin.weight == $0) }) { index in
            let weight = DigitWeight.allCases[index]
            withAnimation(Motion.snap) {
                model.settings.skin.weight = weight
                model.markSkinCustom()
            }
        }
    }

    private var ringRow: some View {
        optionRow(label: "秒环", options: RingFace.allCases.map { ($0.label, model.settings.skin.ring == $0) }) { index in
            let ring = RingFace.allCases[index]
            withAnimation(Motion.snap) {
                model.settings.skin.ring = ring
                model.markSkinCustom()
            }
        }
    }

    private func optionRow(
        label: String,
        options: [(String, Bool)],
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: Space.s) {
            Text(label)
                .font(Typeface.caption)
                .foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: Space.m)
            HStack(spacing: 3) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        onSelect(index)
                    } label: {
                        Text(option.0)
                            .font(Typeface.micro)
                            .tracking(0.8)
                            .foregroundStyle(option.1 ? Palette.ink : Palette.inkTertiary)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(option.1 ? Palette.wash(0.08) : .clear)
                            )
                    }
                    .buttonStyle(PressableStyle(scale: 0.94))
                }
            }
        }
        .padding(.vertical, Space.s)
    }

    private var gradientRow: some View {
        HStack(spacing: Space.s) {
            Text("渐变数字")
                .font(Typeface.caption)
                .foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: Space.m)
            Toggle("", isOn: $model.settings.skin.gradient)
                .labelsHidden()
                .tint(model.settings.skin.accentColor)
                .scaleEffect(0.85)
                .onChange(of: model.settings.skin.gradient) { _, _ in
                    model.markSkinCustom()
                }
        }
        .padding(.vertical, Space.s)
    }

    /// The gradient's second stop gets its own hue because it is the one colour
    /// in the skin allowed to disagree with the accent: that disagreement is what
    /// makes the numerals read as lit from above.
    private var gradientHueRow: some View {
        sliderRow(
            label: "渐变终点",
            value: "\(Int(gradientHue.wrappedValue.rounded()))°",
            tint: model.settings.skin.gradientTo.color,
            disabled: !model.settings.skin.gradient
        ) {
            Slider(value: gradientHue, in: 0...360, step: 1)
        }
    }

    private var gradientHue: Binding<Double> {
        Binding(
            get: {
                let skin = model.settings.skin
                let end = skin.gradientTo.hsv
                let hue = end.saturation < 0.02 ? skin.accent.hsv.hue : end.hue
                return hue * 360
            },
            set: { degrees in
                var skin = model.settings.skin
                skin.gradientTo = skin.gradientTo.withHueSaturation(
                    hue: degrees,
                    saturation: skin.gradientTo.hsv.saturation
                )
                model.settings.skin = skin
                model.markSkinCustom()
            }
        )
    }

    // MARK: Background

    /// Six shapes for the room and the two knobs worth exposing. The skin still
    /// owns the colours; a background only decides how they are arranged. Each
    /// card previews its own style with the current skin, so the choice is made
    /// on the actual pixels instead of on a name.
    private var backgroundSection: some View {
        section(title: "背景") {
            VStack(alignment: .leading, spacing: Space.l) {
                LazyVGrid(columns: backgroundColumns, spacing: Space.s) {
                    ForEach(AppSettings.BackgroundStyle.allCases) { style in
                        backgroundCard(style)
                    }
                }

                VStack(spacing: 0) {
                    sliderRow(
                        label: "强度",
                        value: "\(Int((model.settings.backgroundIntensity * 100).rounded()))%",
                        tint: model.settings.skin.accentColor
                    ) {
                        Slider(value: $model.settings.backgroundIntensity, in: 0...1, step: 0.01)
                    }

                    sliderRow(
                        label: "色相偏移",
                        value: signedDegrees(model.settings.backgroundHueShift),
                        tint: model.settings.skin.accentColor
                    ) {
                        Slider(value: $model.settings.backgroundHueShift, in: -0.5...0.5, step: 0.01)
                    }
                }
            }
        }
    }

    /// Adaptive rather than a fixed two columns: on the iPad sheet this lays out
    /// 2 × 3, and on a narrow iPhone sheet it collapses to one readable column
    /// instead of squeezing each card's description into two characters a line.
    private var backgroundColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 250), spacing: Space.s)]
    }

    private func backgroundCard(_ style: AppSettings.BackgroundStyle) -> some View {
        let active = model.settings.background == style

        return Button {
            withAnimation(Motion.snap) { model.settings.background = style }
            Haptics.tap()
        } label: {
            HStack(spacing: Space.m) {
                BackgroundLayer(
                    spec: BackgroundSpec(settings: model.settings, style: style, phase: 0.7)
                )
                .frame(width: 88, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: Metrics.hairline)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(style.label)
                        .font(Typeface.caption)
                        .foregroundStyle(active ? Palette.ink : Palette.inkSecondary)
                    Text(style.detail)
                        .font(Typeface.micro)
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(active ? Palette.wash(0.06) : Palette.wash(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(
                        active ? Palette.hairlineStrong : Palette.hairline,
                        lineWidth: Metrics.hairline
                    )
            )
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .accessibilityLabel("背景 \(style.label)")
    }

    /// Turns are what the model stores (-0.5...0.5); degrees are what a person
    /// reads. The sign is always shown so "which way did it move" is answerable.
    private func signedDegrees(_ turns: Double) -> String {
        let degrees = Int((turns * 360).rounded())
        return degrees > 0 ? "+\(degrees)°" : "\(degrees)°"
    }

    // MARK: Display

    private var displaySection: some View {
        section(title: "时间显示") {
            VStack(spacing: 0) {
                HStack(spacing: Space.s) {
                    ForEach(AppSettings.ClockStyle.allCases) { style in
                        Button {
                            withAnimation(Motion.snap) { model.settings.clockStyle = style }
                        } label: {
                            Text(style.label)
                                .font(Typeface.caption)
                                .foregroundStyle(model.settings.clockStyle == style ? Palette.ink : Palette.inkTertiary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                        .fill(model.settings.clockStyle == style ? Palette.wash(0.09) : .clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                        .strokeBorder(
                                            model.settings.clockStyle == style ? Palette.hairlineStrong : Palette.hairline,
                                            lineWidth: Metrics.hairline
                                        )
                                )
                        }
                        .buttonStyle(PressableStyle(scale: 0.97))
                    }
                }
                .padding(.bottom, Space.s)

                SettingsToggle(title: "24 小时制", detail: "关闭后使用 12 小时制并显示上午/下午", isOn: $model.settings.use24Hour)
                SettingsToggle(title: "显示秒", detail: "主时间右侧的秒数与秒环", isOn: $model.settings.showSeconds)
                SettingsToggle(title: "显示农历", detail: "顶部日期行右侧的农历月日", isOn: $model.settings.showLunar)

                // Ambient adaptation sits above night dimming because when it is
                // available it *replaces* the night window rather than stacking
                // with it. Default source is the screen backlight: free, no
                // permission, and it already tracks the room on a device with
                // Auto-Brightness on. The camera is an opt-in extra, because an
                // always-on capture session is what made the first version hot.
                SettingsToggle(
                    title: "环境光自适应",
                    detail: "跟随屏幕亮度推算环境光；暗处自动降亮但保底可读",
                    isOn: $model.settings.ambientAdaptive,
                    note: ambientReadout,
                    noteColor: model.ambientAvailable ? Palette.ember : Palette.inkQuaternary
                )

                if model.settings.ambientAdaptive {
                    SettingsToggle(
                        title: "精确测光（更准，略费电）",
                        detail: "每 30 秒用前置摄像头采样 0.35 秒，其余时间相机断电",
                        isOn: $model.settings.ambientPrecise,
                        note: model.currentAmbientNote(),
                        noteColor: Palette.inkQuaternary
                    )
                }

                // Kept, not removed: the night window is still the fallback when
                // the camera is unavailable. It just steps aside visually while
                // the sensor is driving brightness.
                SettingsToggle(title: "夜间调暗", detail: "在设定时段内降低画面对比", isOn: $model.settings.dimAtNight)
                    .opacity(model.settings.ambientAdaptive ? 0.45 : 1)
                if model.settings.dimAtNight {
                    nightRange
                        .opacity(model.settings.ambientAdaptive ? 0.45 : 1)
                }
                if model.settings.ambientAdaptive {
                    Text("环境光自适应已接管亮度")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Space.xs)
                        .padding(.bottom, Space.m)
                }

                SettingsToggle(title: "防烧屏微位移", detail: "每 30 分钟整体平移 1 点，长期常亮更安全", isOn: $model.settings.burnInDrift)
                SettingsToggle(
                    title: "防烧屏演示",
                    detail: "正常模式是每 30 分钟 1pt，肉眼不可见；演示模式放大到 8pt/2 秒，用来确认它在动",
                    isOn: $model.burnInPreview,
                    note: model.settings.burnInDrift ? "已启用 · 每 30 分钟 1pt" : "已关闭",
                    noteColor: model.settings.burnInDrift ? Palette.ember : Palette.inkQuaternary
                )
                SettingsToggle(title: "保持屏幕常亮", detail: "作为时钟放置时阻止自动锁屏", isOn: $model.settings.keepAwake)
            }
        }
    }

    /// A switch that silently reacts to the room is worse than no switch, so the
    /// current reading and the resulting screen brightness are always spelled
    /// out. The curve matches ClockStage.stageOpacity exactly.
    private var ambientReadout: String {
        guard model.ambientAvailable else {
            return "尚未取到读数（打开后约 1 秒）"
        }
        let level = min(1, max(0, model.ambientLevel))
        let brightness = Int(((0.55 + level * 0.45) * 100).rounded())
        return String(format: "环境亮度 %.2f · 画面 %d%%", level, brightness)
    }

    private var nightRange: some View {
        HStack(spacing: Space.m) {
            Text("时段")
                .font(Typeface.caption)
                .foregroundStyle(Palette.inkTertiary)
            Spacer()
            hourStepper(value: $model.settings.nightStartHour)
            Text("至")
                .font(Typeface.caption)
                .foregroundStyle(Palette.inkQuaternary)
            hourStepper(value: $model.settings.nightEndHour)
        }
        .padding(.vertical, Space.m)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func hourStepper(value: Binding<Int>) -> some View {
        HStack(spacing: Space.s) {
            stepButton("minus") {
                value.wrappedValue = (value.wrappedValue + 23) % 24
            }
            Text(String(format: "%02d:00", value.wrappedValue))
                .font(Typeface.digit(13))
                .foregroundStyle(Palette.ink)
                .frame(width: 52)
            stepButton("plus") {
                value.wrappedValue = (value.wrappedValue + 1) % 24
            }
        }
        .padding(.horizontal, Space.xs)
        .background(
            Capsule().fill(Palette.wash(0.04))
        )
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: Metrics.hairline))
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(PressableStyle(scale: 0.92))
    }

    // MARK: Server

    private var serverSection: some View {
        section(title: "服务器") {
            VStack(spacing: Space.m) {
                field(label: "地址") {
                    TextField("http://192.168.1.10:8787", text: $model.config.baseURL)
                        .textFieldStyle(.plain)
                        .font(Typeface.body)
                        .foregroundStyle(Palette.ink)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                field(label: "令牌") {
                    SecureField("Bearer token", text: $model.config.token)
                        .textFieldStyle(.plain)
                        .font(Typeface.body)
                        .foregroundStyle(Palette.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                SettingsToggle(title: "自动同步", detail: "前台每 \(Int(model.config.syncInterval)) 秒校准一次", isOn: $model.config.autoSync)
                SettingsToggle(title: "信任自签名证书", detail: "用 https://<IP> 连自己的服务器时打开；只对该地址生效", isOn: $model.settings.allowSelfSignedCertificates)

                HStack(spacing: Space.m) {
                    SyncStatusLine()
                    Spacer()
                    Button {
                        runDiagnostics()
                    } label: {
                        Text(diagnosing ? "检测中" : "测试连接")
                            .font(Typeface.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .padding(.horizontal, Space.m)
                            .frame(height: 32)
                            .background(Capsule().fill(Palette.wash(0.04)))
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: Metrics.hairline))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(diagnosing)

                    Button {
                        model.saveConfig()
                        model.syncNow()
                        Haptics.commit()
                    } label: {
                        Text(model.syncPhase == .syncing ? "同步中" : "立即同步")
                            .font(Typeface.caption)
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, Space.l)
                            .frame(height: 32)
                            .background(Capsule().fill(Palette.wash(0.07)))
                            .overlay(Capsule().strokeBorder(Palette.hairlineStrong, lineWidth: Metrics.hairline))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(model.syncPhase == .syncing)
                }
                .padding(.top, Space.xs)

                if let diagnostic {
                    Text(diagnostic)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.inkSecondary)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.m)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                .fill(Palette.wash(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: Metrics.hairline)
                        )
                }

                if let detail = model.syncDetail, !detail.isEmpty {
                    Text(detail)
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.ember)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("服务器地址填局域网内的 http 地址即可；公网请走 https。任务由服务器下发，勾选状态会回写。")
                    .font(Typeface.caption)
                    .foregroundStyle(Palette.inkQuaternary)
                    .lineSpacing(3)
                    .padding(.top, Space.xs)
            }
        }
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Space.l) {
            Text(label)
                .font(Typeface.caption)
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 44, alignment: .leading)
            content()
                .padding(.vertical, Space.m)
                .padding(.horizontal, Space.m)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Palette.wash(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: Metrics.hairline)
                )
        }
    }

    // MARK: About

    private var aboutSection: some View {
        section(title: "关于") {
            VStack(spacing: 0) {
                KeyValueRow(label: "版本") {
                    Text(BuildTag.label)
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .padding(.vertical, Space.m)
                .overlay(alignment: .bottom) { Hairline() }

                // The only "updater" iOS permits: we can tell you a newer build
                // exists and open its page. The install itself belongs to
                // TrollStore / AltStore, which is why the row never pretends to
                // be a download.
                updateRow
                    .padding(.vertical, Space.m)
                    .overlay(alignment: .bottom) { Hairline() }

                KeyValueRow(label: "任务") {
                    Text("\(model.tasks.count) 条 · 今日 \(model.doneTodayCount)/\(model.todayTasks.count)")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .padding(.vertical, Space.m)
                .overlay(alignment: .bottom) { Hairline() }

                KeyValueRow(label: "数据") {
                    Text("本地缓存 · 离线可用")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .padding(.vertical, Space.m)
            }
        }
    }

    private var updateRow: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("更新")
                        .font(Typeface.caption)
                        .tracking(0.6)
                        .foregroundStyle(Palette.inkTertiary)
                    Text(model.updateNote())
                        .font(Typeface.caption)
                        .foregroundStyle(model.availableUpdate == nil ? Palette.inkSecondary : Palette.ember)
                        .lineLimit(2)
                }
                Spacer(minLength: Space.s)

                if let update = model.availableUpdate {
                    Button {
                        Haptics.commit()
                        model.openUpdate(update)
                    } label: {
                        Text("安装 \(update.tag)")
                            .font(Typeface.caption)
                            .foregroundStyle(Palette.canvas)
                            .padding(.horizontal, Space.l)
                            .frame(height: 32)
                            .background(Capsule().fill(model.settings.skin.accentColor))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("安装新版本 \(update.tag)")
                } else {
                    Button {
                        model.checkForUpdate(force: true)
                        Haptics.tap()
                    } label: {
                        Text("检查")
                            .font(Typeface.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .padding(.horizontal, Space.m)
                            .frame(height: 32)
                            .background(Capsule().fill(Palette.wash(0.04)))
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: Metrics.hairline))
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            if let update = model.availableUpdate {
                Text("构建 \(update.builtAt) · md5 \(update.md5.prefix(8))")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.inkQuaternary)
            } else if model.config.isConfigured {
                Text("覆盖安装即可，配置与待办都会保留。首次安装请用 TrollStore 打开 IPA。")
                    .font(Typeface.caption)
                    .foregroundStyle(Palette.inkQuaternary)
                    .lineSpacing(2)
            }
        }
    }

    // MARK: Diagnostics

    /// Probes https and http against the configured host and prints the real
    /// status or error code. Deliberately not a "magic fix" button: the point is
    /// to make the failure legible, then let the switch above fix it.
    private func runDiagnostics() {
        guard !diagnosing else { return }
        // Persist first: the probe must run against the address in the field,
        // and saving is also what registers the host for self-signed trust.
        model.saveConfig()
        diagnosing = true
        let base = model.config.baseURL
        Task { @MainActor in
            let report = await Diagnostics.run(
                baseURL: base,
                allowSelfSigned: model.settings.allowSelfSignedCertificates
            )
            diagnostic = report
            diagnosing = false
        }
    }

    // MARK: Scaffolding

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            CapsLabel(text: title)
            content()
        }
    }
}

// MARK: - Live preview

/// A fixed miniature of the stage: same skin, same background layer, same
/// numerals at 21:47. It deliberately does not tick — a moving preview would
/// compete with the controls it exists to explain, and the point is the look,
/// not the time.
private struct SkinPreview: View {
    let settings: AppSettings

    var body: some View {
        ZStack {
            BackgroundLayer(spec: BackgroundSpec(settings: settings, phase: 0.7))

            // Same arrangement as the stage's time row — numerals with the
            // seconds ring on their right — because a preview laid out
            // differently would answer the wrong question.
            HStack(alignment: .center, spacing: Space.m) {
                Text("21:47")
                    .font(settings.skin.numerals(38))
                    .foregroundStyle(settings.skin.numeralStyle)
                SecondRing(
                    second: 47,
                    diameter: 26,
                    accent: settings.skin.accentColor,
                    face: settings.skin.ring
                )
            }
        }
        .frame(width: 260, height: 120)
        // The sheet inherits the stage's environment, but the preview must show
        // what is *being edited*, not what was saved when it opened.
        .environment(\.skin, settings.skin)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: Metrics.hairline)
        )
        .overlay(alignment: .topLeading) {
            Text(settings.skin.name)
                .font(Typeface.micro)
                .tracking(1.4)
                .foregroundStyle(settings.skin.inkColor.opacity(0.5))
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
        }
    }
}

// MARK: - Rows

private struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    /// A live state line under the description, e.g. the current ambient reading
    /// or whether the drift it demonstrates is actually enabled. Separate from
    /// `detail` because `detail` explains the switch and this reports what it is
    /// doing right now.
    var note: String? = nil
    var noteColor: Color = Palette.inkTertiary

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typeface.bodyMedium)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(Typeface.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(2)
                if let note {
                    Text(note)
                        .font(Typeface.caption)
                        .foregroundStyle(noteColor)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: Space.m)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Palette.ember)
                .scaleEffect(0.85)
        }
        .padding(.vertical, Space.m)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct SyncStatusLine: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color, pulsing: model.syncPhase == .syncing)
            Text(text)
                .font(Typeface.micro)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch model.syncPhase {
        case .live, .polling: return Palette.inkSecondary
        case .syncing: return Palette.ember
        case .failed: return Palette.ember
        default: return Palette.inkQuaternary
        }
    }

    private var text: String {
        switch model.syncPhase {
        case .failed(let message): return message
        default: return model.syncPhase.title
        }
    }
}
