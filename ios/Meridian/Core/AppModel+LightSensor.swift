//
//  AppModel+LightSensor.swift
//  Meridian — the ambient-adaptation face of the store. OWNER: lead (rewritten
//  when the always-on camera turned out to cost too much battery).
//
//  Two sources, one switch:
//
//    环境光自适应 off          nothing runs
//    on, 精确测光 off           screen backlight only — free, no permission
//    on, 精确测光 on            350ms camera bursts every 30s + backlight
//
//  The screen reading is always the fallback, which is why a denied camera
//  permission degrades silently instead of leaving the feature dead.
//

import Foundation

/// One sensor for the whole process: an `extension` cannot hold stored
/// properties, and two capture sessions would fight over the camera.
private let sharedLightSensor = LightSensor()

extension AppModel {

    /// Brings the sensor in line with the two switches. Idempotent.
    func syncAmbientSensing() {
        guard settings.ambientAdaptive else {
            sharedLightSensor.stop()
            if ambientAvailable {
                ambientAvailable = false
            }
            return
        }

        sharedLightSensor.onLevel = { [weak self] level in
            guard let self else { return }
            self.ambientLevel = min(1, max(0, level))
            if !self.ambientAvailable {
                self.ambientAvailable = true
            }
        }

        let mode: LightSensor.Mode = settings.ambientPrecise ? .precise : .screen
        sharedLightSensor.start(mode: mode) { [weak self] running in
            guard let self else { return }
            self.ambientAvailable = running
        }
    }

    /// One line for the settings row. Describes what is actually happening, not
    /// what was requested — "相机不可用，已退回屏幕亮度" is the sentence a person
    /// needs after dismissing the permission prompt.
    func currentAmbientNote() -> String {
        guard settings.ambientAdaptive else { return "已关闭" }
        if settings.ambientPrecise {
            guard ambientAvailable else { return "相机不可用，已退回屏幕亮度" }
            return String(format: "摄像头 + 屏幕 · 每 30s · 亮度 %.2f", ambientLevel)
        }
        return String(format: "屏幕亮度推算 · %.2f", ambientLevel)
    }
}
