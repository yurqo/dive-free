import SwiftUI

/// In-app user guide for divers, reached from Settings (and the empty Dives
/// screen). Each chapter shows an always-visible intro plus a collapsible
/// "More details" for the deeper explanation.
///
/// Audience: divers, not engineers — keep the language plain and practical.
/// IMPORTANT: keep this in step with the app. Whenever a feature or a piece of
/// behaviour changes, update the matching chapter in `UserGuide.chapters` below.
struct UserGuideView: View {
    var body: some View {
        List {
            ForEach(UserGuide.chapters) { chapter in
                Section {
                    ForEach(chapter.intro.indices, id: \.self) { i in
                        GuideBlockView(block: chapter.intro[i])
                    }
                    if !chapter.details.isEmpty {
                        DisclosureGroup("More details") {
                            ForEach(chapter.details.indices, id: \.self) { i in
                                GuideBlockView(block: chapter.details[i])
                            }
                        }
                        .tint(.teal)
                        .font(.subheadline.weight(.medium))
                    }
                } header: {
                    Label(chapter.title, systemImage: chapter.systemImage)
                        .font(.headline)
                        .textCase(nil)
                        .foregroundStyle(.primary)
                }
            }
            Section {
                Text("Dive safe, dive with a buddy, and enjoy the water.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Rendering

/// One line of guide content, rendered by kind.
private struct GuideBlockView: View {
    let block: GuideBlock

    var body: some View {
        switch block {
        case .text(let s):
            Text(GuideBlock.markdown(s))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

        case .subheading(let s):
            Text(s)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.top, 2)

        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.teal)
                Text(GuideBlock.markdown(s))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .step(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(n)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.teal))
                Text(GuideBlock.markdown(s))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .tip(let s):
            Label {
                Text(GuideBlock.markdown(s)).font(.footnote)
            } icon: {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Content model

/// A single line of guide content. Text supports simple **bold**/_italic_ markdown.
private enum GuideBlock {
    case text(String)
    case subheading(String)
    case bullet(String)
    case step(Int, String)
    case tip(String)

    /// Parses inline markdown so key terms can be emphasised; falls back to plain
    /// text if the string somehow fails to parse.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

private struct GuideChapter: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    /// Always visible under the chapter header.
    let intro: [GuideBlock]
    /// Revealed under a "More details" disclosure. May be empty.
    let details: [GuideBlock]
}

private enum UserGuide {
    static let chapters: [GuideChapter] = [
        quickStart,
        howDevicesWorkTogether,
        onYourWatch,
        onYourPhone,
        onYourPad,
        diveDetection,
        photosAndVideos,
        iCloudSync,
        strava,
        safety,
        troubleshooting,
    ]

    // MARK: Chapters

    private static let quickStart = GuideChapter(
        title: "Quick Start",
        systemImage: "bolt.fill",
        intro: [
            .step(1, "Wear your Apple Watch snug and open **Dive Free** on it. Tap **Start** — or press the **Action button** on Apple Watch Ultra if you've assigned Dive Free to it."),
            .step(2, "Dive. The watch locks its screen in the water and records everything hands-free. Turn the **Digital Crown** to pick a marker and press the **Action button** to drop it."),
            .step(3, "Back at the surface, end the session on the watch. It saves itself and appears on your iPhone and iPad, where you can relive it with depth charts, maps, and photos."),
        ],
        details: [
            .text("You never have to touch your iPhone to record a dive — the watch does the recording. Your iPhone and iPad are where you look back on everything afterwards."),
            .tip("New to the watch controls? There's a short guide on the watch itself, on its Start screen."),
        ]
    )

    private static let howDevicesWorkTogether = GuideChapter(
        title: "How your devices work together",
        systemImage: "arrow.triangle.2.circlepath",
        intro: [
            .text("Dive Free is a **logbook and travel memory** for your time in the water — not a dive computer. Each device has its own job:"),
            .bullet("**Apple Watch** is your in-water recorder: depth, dives, markers, heart rate, and your surface GPS track."),
            .bullet("**iPhone and iPad** are your logbook: browse sessions, see depth charts and maps, add photos and notes, and share."),
        ],
        details: [
            .subheading("Getting a dive to your phone"),
            .text("When you end a session, the watch sends it straight to your iPhone over their direct link — no internet or iCloud required. Keep the watch near the phone afterwards and the dive arrives within moments. If one ever doesn't, you can re-send it from the watch (see Troubleshooting)."),
            .subheading("Following a dive live"),
            .text("While a session runs on the watch, your iPhone shows it live: a banner at the top of the **Dives** tab, plus a Live Activity on the Lock Screen and in the Dynamic Island."),
            .text("A **green dot** means the phone is hearing from the watch; **grey** means they're briefly out of range — normal when your phone is on the boat and you're in the water. The timer keeps counting as an estimate and catches up once they reconnect."),
            .subheading("Then iCloud ties it together"),
            .text("Your saved dives, spots, and photos sync across iPhone and iPad through your own iCloud, so your log looks the same everywhere."),
        ]
    )

    private static let onYourWatch = GuideChapter(
        title: "On your wrist: the Apple Watch",
        systemImage: "applewatch",
        intro: [
            .text("Underwater the touchscreen locks — that's normal, since water triggers stray taps. So the dive is driven entirely by two physical controls:"),
            .bullet("**Digital Crown** — scrolls through your markers. Works above and below the surface."),
            .bullet("**Action button** (Apple Watch Ultra) — drops the highlighted marker underwater, and confirms your choice at the surface."),
        ],
        details: [
            .subheading("Setting up the Action button"),
            .text("Dive Free runs as a **Workout** on your watch, so you assign the Action button under **Settings ▸ Action Button ▸ Workout ▸ Dive Free** (pick the Freedive workout) — not under “App.” The first press starts a session; while one is running, a press drops a marker."),
            .text("It appears as a *Workout* rather than a dedicated “dive” because Dive Free is a recreational logbook built on Apple's workout tools, not a dive computer — the recording is exactly the same, it's just filed under Workout."),
            .subheading("Markers"),
            .text("Markers are little flags you drop during a dive — wildlife, a hazard, a photo moment, or your own custom kinds. Turn the Crown to the one you want and press the Action button to drop it. Set your most-used marker as the **default** in the watch's Settings; it's pre-selected, and it's what a quick Action-button press drops."),
            .subheading("Underwater the menu is shorter"),
            .text("While you're submerged the menu shows **markers only**. Voice notes and ending a session don't work underwater, so they're tucked away to keep things simple — they return the instant you surface."),
            .subheading("Voice notes"),
            .text("At the surface, scroll to **Voice Note** and confirm to record a quick thought; confirm again to stop. It attaches to your last marker, and stops automatically if you dive."),
            .subheading("Marking a dive by hand"),
            .text("Press the **Action + side buttons together** to start a dive the moment you drop, and again to end it — handy for very shallow dives that automatic detection might miss. Otherwise the watch detects dives for you."),
            .subheading("Ending a session"),
            .text("At the surface, scroll the Crown to **End** and press the Action button; in the confirmation, Action + side ends it and the Action button cancels. On a watch without an Action button, turn the Crown to unlock the screen, then tap."),
            .subheading("What the numbers mean"),
            .bullet("**Big timer** — your current dive time underwater, or your surface recovery time between dives."),
            .bullet("**Recovery colour** — after a dive the timer is tinted by how long you've rested versus your last dive: red under 1×, orange under 2×, yellow under 3×, white once well rested. A gentle nudge to pace yourself, not medical advice."),
            .bullet("**Depth** shows underwater on Apple Watch Ultra, Series 10, and Series 11. Other watches skip depth but still log your GPS track, markers, and heart rate."),
            .bullet("**Heart rate** beats on the right on any watch; **water temperature** shows on the left on Ultra while you're under."),
            .bullet("**GPS** (top-left) tags where you dived — let it get a fix at the surface before you drop, since GPS can't reach underwater."),
            .subheading("Time cues"),
            .text("Turn on periodic taps and tones during a dive in the watch's Settings for a sense of elapsed time without looking. Pick the short and long intervals that suit you."),
            .subheading("Watch storage"),
            .text("The watch keeps every dive locally and also sends it to your iPhone. To free up watch space, turn on **auto-clean** in the watch's Settings ▸ Storage — it removes older sessions from the watch (by age, count, or size), **only once they're safely on your iPhone**. Your dives always stay on iPhone and iCloud."),
            .tip("Wear the watch a finger-width above the wrist bone and tighten the strap before diving — a snug fit keeps the heart-rate sensor reading, especially in cold water."),
        ]
    )

    private static let onYourPhone = GuideChapter(
        title: "On your iPhone: your logbook",
        systemImage: "iphone",
        intro: [
            .text("Everything you record lands here. The app has four tabs:"),
            .bullet("**Dives** — every session, newest first."),
            .bullet("**Spots** — your dive sites, grouped by location and shown on a map."),
            .bullet("**Passport** — your totals and milestones."),
            .bullet("**Trips** — group dives into multi-day adventures."),
        ],
        details: [
            .subheading("A single dive"),
            .text("Tap any session to open it: a **depth-profile chart** for each dive, a map of where you were, your markers along the timeline, photos and videos from that day, voice notes you can play back, plus water temperature, heart rate, and calories where available. Voice notes sync to your other devices automatically, so a clip you recorded on the watch plays back on your iPad too."),
            .subheading("Editing and rating"),
            .text("Give a session a title, a star rating, and notes. You can tidy up details and remove a session you didn't mean to keep."),
            .subheading("Spots"),
            .text("Dives at the same place are gathered into a **spot** automatically, each with its own map and history — a quick way to see how a favourite site has treated you over time. Swipe a spot to remove it — handy for a stray empty one left after you deleted its dives."),
            .subheading("Trips"),
            .text("Bundle several days of diving into a **trip** — perfect for a liveaboard or a week away — and see the trip's totals in one place. Swipe a trip to remove it; deleting a trip keeps its dives in your log."),
            .subheading("Passport"),
            .text("Your diving at a glance: number of dives, time in the water, places visited, and milestones that grow as you log more."),
            .subheading("Settings"),
            .text("Open Settings from the gear icon on the **Dives** tab to choose your **units** (metric, imperial, or a custom mix — it syncs to the watch), manage **custom markers**, check **iCloud sync**, and connect **Strava**."),
        ]
    )

    private static let onYourPad = GuideChapter(
        title: "On your iPad",
        systemImage: "ipad",
        intro: [
            .text("Dive Free is the same app on iPad, with room to breathe: a sidebar for the tabs and a larger canvas for depth charts, maps, and photo galleries."),
        ],
        details: [
            .text("Your dives, spots, and photos arrive on iPad automatically through iCloud, so you can plan and reminisce on the bigger screen. Everything you can do on iPhone, you can do here."),
            .tip("The iPad doesn't record dives itself — that's the watch's job — but it's the nicest way to look back on them."),
        ]
    )

    private static let diveDetection = GuideChapter(
        title: "How dives are detected",
        systemImage: "waveform.path.ecg",
        intro: [
            .text("Dive Free records depth continuously and works out where one dive ends and the next begins, so your log matches what you actually did."),
            .bullet("A **dive** starts when you drop below the surface and ends when you come back up."),
            .bullet("The gap between dives is your **surface interval** — your recovery time."),
        ],
        details: [
            .subheading("What counts as a dive"),
            .text("So genuine dives register but brief surface bobbing doesn't, detection is **tiered** — the deeper you go, the sooner it counts. A dive is logged as soon as it meets any one of these:"),
            .bullet("A quick drop to about **2 m** registers within a couple of seconds — for duck dives."),
            .bullet("A dive to about **1.5 m** registers after about **3 seconds**."),
            .bullet("A shallow dive past **1 m** registers if you stay down about **10 seconds** — so pool and shallow snorkel dives are logged, while a brief bob at the surface isn't."),
            .subheading("The descent countdown"),
            .text("As you go under, the depth and a small greyed **countdown** appear beside the surface icon on the watch, showing how long until the dive registers — it shrinks as you go deeper. When it reaches zero the screen switches to your live dive time. It's handy in shallow water, where you can watch a dive lock in."),
            .subheading("Manual dives"),
            .text("For a very shallow or quick drop you want to be sure is logged, mark the dive by hand with **Action + side** (see the watch chapter) — it counts from the moment you press, whatever the depth."),
            .subheading("About depth"),
            .text("Depth is measured in shallow water only — up to about **6 m (20 ft)**. Dive Free is built for recreational freediving and snorkelling, so it doesn't measure or plan deep dives, and maximum depth stops at that ceiling."),
        ]
    )

    private static let photosAndVideos = GuideChapter(
        title: "Photos & videos",
        systemImage: "photo.on.rectangle",
        intro: [
            .text("Relive a dive with the photos and videos you took that day — including shots from an underwater camera you've imported to your phone."),
        ],
        details: [
            .subheading("Adding media"),
            .text("Open a session and add photos or videos from your library. **Suggest from This Dive** finds shots taken during the session's time window, so you don't have to hunt for them."),
            .subheading("Albums"),
            .text("Dive Free can gather your dive media into a **Dive Free** album in Photos, keeping a session's shots together."),
            .text("Your photos stay in your own photo library and iCloud — Dive Free simply points to them. They're never uploaded to us, and they aren't sent to Strava."),
        ]
    )

    private static let iCloudSync = GuideChapter(
        title: "Keeping devices in sync",
        systemImage: "icloud",
        intro: [
            .text("Your dive log, spots, and photos sync privately across your iPhone and iPad through **your own iCloud account**. Turn it on or off in Settings ▸ iCloud."),
        ],
        details: [
            .text("Sync uses your **private** iCloud database — your data stays in your iCloud and isn't visible to us. Sign in to iCloud with the same Apple Account on both devices."),
            .subheading("How fast is it?"),
            .text("Changes travel in the background and usually appear within a minute or two, depending on your connection. Settings ▸ iCloud shows the current sync status if you're curious."),
            .subheading("Where the watch fits"),
            .text("The watch doesn't use iCloud — it sends dives straight to your iPhone over their direct link. From there, iCloud carries them on to your iPad."),
            .tip("A brand-new dive first appears on the iPhone the watch talked to, then syncs to your other devices."),
        ]
    )

    private static let strava = GuideChapter(
        title: "Sharing to Strava",
        systemImage: "square.and.arrow.up",
        intro: [
            .text("Export any dive you like to **Strava** as an activity, complete with your GPS track, heart rate, and depth."),
        ],
        details: [
            .text("Connect your Strava account once in Settings ▸ Strava. Then, from a session, choose to export it — you pick which dives to share, and nothing is sent automatically."),
            .text("Photos can't be added to a Strava activity through Strava's public tools, so add those on Strava yourself if you'd like."),
        ]
    )

    private static let safety = GuideChapter(
        title: "Safety & the fine print",
        systemImage: "exclamationmark.triangle.fill",
        intro: [
            .text("**Dive Free is a logbook, not a dive computer.** It provides no decompression, dive-planning, or safety information, and it is not a safety device."),
            .bullet("Always dive within your training and certification."),
            .bullet("Follow your local rules and the conditions on the day."),
            .bullet("**Never freedive alone** — always dive with a trained buddy."),
        ],
        details: [
            .text("Depth tracking is limited to shallow water (about 6 m / 20 ft) and exists to help you remember your dives, not to guide them. Never rely on Dive Free for any decision that affects your safety."),
        ]
    )

    private static let troubleshooting = GuideChapter(
        title: "Troubleshooting",
        systemImage: "wrench.and.screwdriver.fill",
        intro: [
            .text("Quick answers to the questions that come up most."),
        ],
        details: [
            .subheading("My dive isn't on my iPhone"),
            .text("Keep the watch near the phone with both apps opened recently — the watch delivers sessions over their direct link when they're close. Then give iCloud a minute to carry it on to your iPad."),
            .text("Still missing? On the watch, open that session and tap **Re-send to iPhone** — or use **Settings ▸ Sync ▸ Re-send all to iPhone** to push everything again."),
            .subheading("No depth during a dive"),
            .text("Depth needs an Apple Watch Ultra, Series 10, or Series 11. Other watches log the GPS track, markers, and heart rate instead."),
            .subheading("The Action button does nothing"),
            .text("On Apple Watch Ultra, assign Dive Free under the watch's Settings ▸ Action Button ▸ **Workout** ▸ Dive Free — it runs as a workout, so it's under Workout, not “App.” Without it, use the on-screen controls at the surface (see the watch chapter)."),
            .subheading("The live banner says \u{201C}Reconnecting…\u{201D}"),
            .text("That just means your phone and watch are briefly out of range — completely normal when the phone is on the boat. Your dive is still being recorded; the log fills in once they're back together."),
            .subheading("Photos aren't reaching my iPad"),
            .text("Check that iCloud sync is on (Settings ▸ iCloud) and that you're signed into the same Apple Account on both devices, then give it a little time."),
        ]
    )
}

#Preview {
    NavigationStack {
        UserGuideView()
    }
}
