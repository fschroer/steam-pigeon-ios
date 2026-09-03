// `@preconcurrency`: AVFoundation predates Sendable annotation, so a session, a device
// and an input all count as non-Sendable when this type hands them to its own serial
// queue — which is exactly the arrangement Apple's own documentation asks for, since
// configuring, starting and stopping a session all block and must not run on the main
// thread.
@preconcurrency import AVFoundation
import SwiftUI

/// The back camera, running behind the landscape AR overlay.
///
/// Android's `CameraPreviewScreen` binds a CameraX `Preview` to the composable's
/// lifecycle and unbinds on dispose; the *camera* here has the same lifetime — it starts
/// when the heads-up view appears and stops when the phone goes back to portrait, so
/// nothing holds it open behind the map.
///
/// **The object outlives the view, deliberately** (`RootView` owns it), and so does the
/// preview view it hands out. Everything expensive about a capture session — finding the
/// device, building the input, attaching the session to a preview layer, and tearing all
/// three down again — is main-thread work that would otherwise land on **every rotation**,
/// in the same run loop turn as the rotation animation and MapLibre's own teardown. That
/// is what a stuck rotation showing half a map screen looks like from the inside
/// (reported from the phone, 2026-09-02). Owned here, the cost is paid once and a rotation
/// only starts or stops a session that is already built, on its own queue.
final class CameraPassthrough: ObservableObject {

    enum Status: Equatable {
        case idle
        case running
        /// The user said no, or an MDM profile did.
        case denied
        /// No back camera, or it refused to configure.
        case unavailable
    }

    @Published private(set) var status: Status = .idle

    /// Android toggles the camera between 1× and its ceiling on a tap, with nothing in
    /// between — no pinch, no intermediate steps. This is which of the two it is on.
    @Published private(set) var zoomedIn = false

    /// The one preview view, built here rather than in `makeUIView` so the session is
    /// attached to it **once**, before that session has ever been configured or started.
    /// Attaching a session takes the session's own lock, so doing it per rotation puts a
    /// main-thread wait directly behind whatever the capture queue happens to be doing.
    let previewView = CameraPreviewView()

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.steampigeon.camera-passthrough")
    /// Both touched only on `queue`.
    private var device: AVCaptureDevice?
    private var configured = false

    init() {
        previewView.previewLayer.videoGravity = .resizeAspectFill
        previewView.previewLayer.session = session
    }

    /// Ask for the camera if it has not been asked for yet, then run.
    ///
    /// **Asked here rather than at launch**, which is where Android asks (`CAMERA` sits in
    /// `requiredPermissions` alongside location and Bluetooth). An iOS prompt at first
    /// launch would arrive with nothing on screen to explain it; asking on the first
    /// rotation into the heads-up view puts the request where the feature is. Recorded in
    /// `docs/UI_PARITY.md`.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.configureAndRun() } else { self.setStatus(.denied) }
            }
        default:
            setStatus(.denied)
        }
    }

    func stop() {
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
        if status == .running { status = .idle }
    }

    /// 1× ⇄ the camera's ceiling, as Android's tap does.
    func toggleZoom() {
        guard status == .running else { return }
        let zoomIn = !zoomedIn
        zoomedIn = zoomIn
        queue.async { [weak self] in
            guard let device = self?.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = zoomIn ? device.maxAvailableVideoZoomFactor : 1
            device.unlockForConfiguration()
        }
    }

    /// All of it on the capture queue — including finding the device and building the
    /// input, which is the slowest part and the one that used to run on the main thread.
    private func configureAndRun() {
        queue.async { [weak self] in
            guard let self else { return }

            if !self.configured {
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: camera),
                      self.session.canAddInput(input) else {
                    self.setStatus(.unavailable)
                    return
                }
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                self.session.addInput(input)
                self.session.commitConfiguration()
                self.device = camera
                self.configured = true
            }

            if !self.session.isRunning { self.session.startRunning() }
            self.setStatus(.running)
        }
    }

    /// `@Published` is read by SwiftUI, so it is written on the main thread even when the
    /// verdict was reached on the capture queue.
    private func setStatus(_ new: Status) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status != new else { return }
            self.status = new
        }
    }
}

/// A `UIView` whose backing layer IS the preview layer, so the video tracks the view's
/// bounds without a second layout pass to resize it.
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // **A 180° flip changes nothing this view would otherwise hear about**: the size
        // class is the same, the bounds are the same, so neither a layout pass nor a
        // SwiftUI update is guaranteed — and the one thing that DID change is the only
        // thing this view cares about. Reported from the phone as a fast
        // landscape-to-landscape flip ending up upside down.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceOrientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// The device notification leads the interface: it fires as the phone turns, while
    /// `interfaceOrientation` is updated by UIKit as the rotation is committed. So this
    /// reads the interface twice — now, and again after the turn of the run loop the
    /// rotation is committed in — rather than trusting the device orientation itself,
    /// which is the enum that means the opposite thing.
    @objc private func deviceOrientationChanged() {
        applyInterfaceOrientation()
        DispatchQueue.main.async { [weak self] in self?.applyInterfaceOrientation() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyInterfaceOrientation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyInterfaceOrientation()
    }

    /// Point the video the same way the interface is pointed.
    ///
    /// **Interface, not device, orientation** — the two are named the same and mean
    /// opposite rotations, and it is the interface one that matches
    /// `AVCaptureVideoOrientation` case for case. A device-orientation table here is the
    /// classic way to get a preview that is upside-down in exactly one of the two
    /// landscapes. Confirmed upright in both on hardware, 2026-09-02.
    ///
    /// `videoOrientation` is deprecated from iOS 17 in favour of `videoRotationAngle`, and
    /// this stays on it deliberately: the app's floor is iOS 16, and one code path that
    /// behaves identically on both of the phones this is tested on beats two that have to
    /// be checked separately.
    @available(iOS, deprecated: 17.0,
               message: "videoOrientation is the one path that also serves iOS 16")
    func applyInterfaceOrientation() {
        guard let connection = previewLayer.connection,
              connection.isVideoOrientationSupported else { return }
        let interface = (window?.windowScene ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)?.interfaceOrientation
        let wanted: AVCaptureVideoOrientation
        switch interface {
        case .portraitUpsideDown: wanted = .portraitUpsideDown
        case .landscapeLeft:      wanted = .landscapeLeft
        case .landscapeRight:     wanted = .landscapeRight
        default:                  wanted = .portrait
        }
        // Only on a change: the heads-up view re-evaluates at the sensor rate, and
        // rewriting this ten times a second would touch the connection for nothing.
        if connection.videoOrientation != wanted { connection.videoOrientation = wanted }
    }
}

/// The preview layer itself, as a SwiftUI view. It hands back the one long-lived view
/// rather than building another — see the note on `CameraPassthrough`.
struct CameraPassthroughView: UIViewRepresentable {
    let camera: CameraPassthrough

    func makeUIView(context: Context) -> CameraPreviewView { camera.previewView }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        view.applyInterfaceOrientation()
    }
}
