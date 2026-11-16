//
//  RootView.swift
//  Meridian — the frame everything sits in.
//
//  Two regions and nothing else: the clock stage (all of the attention) and a
//  single strip of cards (all of the utility). Immersive mode removes the strip
//  with a spring and leaves the time alone on the glass. Any touch brings the
//  chrome back — that is the whole interaction model, and it is the reason the
//  app can sit on a wall for a week without asking for anything.
//

import Combine
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .topLeading) {
            model.settings.skin.canvasColor.ignoresSafeArea()
            AmbientBackground()

            HStack(spacing: 0) {
                ClockStage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.agendaFocus {
                    // Focused: the agenda comes forward, the clock stays put and
                    // only dims — see AgendaFocusCard for why it must not resize.
                    AgendaFocusCard()
                        .frame(width: Metrics.focusStripWidth)
                        .padding(.trailing, Metrics.stageInset)
                } else if model.immersive {
                    // Immersive: three lines and a hairline, so the right edge is
                    // a glance instead of a void.
                    BurnInDrift(enabled: model.settings.burnInDrift) {
                        AgendaGlance()
                            .frame(width: Metrics.glanceStripWidth, alignment: .trailing)
                            .padding(.trailing, Metrics.stageInset)
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                    )
                } else {
                    PanelStrip()
                        .frame(width: Metrics.panelStripWidth)
                        .padding(.trailing, Metrics.stageInset)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                )
                        )
                }
            }
            .padding(.vertical, Metrics.stageInset)

            StatusStrip()
                .padding(.leading, Metrics.stageInset)
                .padding(.bottom, Metrics.stageInset - 10)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .frame(maxWidth: model.immersive ? 520 : 760, alignment: .leading)
                .opacity(model.immersive ? 0 : 1)
                .animation(Motion.fade, value: model.immersive)
                .allowsHitTesting(!model.immersive)
        }
        // `.container` rather than the default `.all`: the keyboard region must
        // stay respected, or the quick-add field ends up behind the keyboard.
        .ignoresSafeArea(.container)
        // The reminder is the last layer in the hierarchy, so it sits above
        // PanelStrip and AgendaFocusCard by construction — no zIndex fight, and
        // nothing added to the existing layout. The host keeps its own hit
        // testing off while there is nothing to show, because an empty overlay
        // covering the glass would eat the stage's tap (the one that walks
        // panel → glance → focus → back).
        .overlay { TaskAlertHost() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        // One injection point: every view that needs the accent reads it from
        // the environment rather than from a global constant.
        .environment(\.skin, model.settings.skin)
        .animation(Motion.settle, value: model.immersive)
        .animation(Motion.settle, value: model.agendaFocus)
        .task {
            model.bootstrapSync()
            model.applyIdleTimer()
            // No-op unless 环境光自适应 is on; when it is, the camera starts on a
            // background queue and the first reading lands ~250ms later.
            model.syncAmbientSensing()
            // One quiet check per launch. It never downloads anything; it only
            // lets the settings row say "有新版本" instead of staying silent.
            model.checkForUpdate()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.applyIdleTimer()
                model.restartSyncIfNeeded()
                // The system interrupts the capture session on background; a
                // foreground return is the moment to start it again.
                model.syncAmbientSensing()
            }
        }
        // The reminder's heartbeat: one tick a second is enough resolution for a
        // due time, and the model owns the policy (one alert at a time, one
        // announcement per task) so this loop can never stack reminders. The
        // work per tick is a filter over today's open tasks.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.announceDueTasks()
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsSheet()
                .environmentObject(model)
                .presentationBackground(Palette.canvasLift)
                .presentationCornerRadius(Radius.panel)
        }
    }
}
