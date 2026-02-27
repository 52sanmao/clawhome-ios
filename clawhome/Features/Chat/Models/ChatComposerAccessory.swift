import Foundation

struct ChatComposerAccessory {
    var hasActiveRuns: Bool = false
    var isStoppingRun: Bool = false
    var showsAttachmentButton: Bool = true
    var onStopRun: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
}
