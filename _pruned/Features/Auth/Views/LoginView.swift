import SwiftUI
import Combine
import AuthenticationServices

// MARK: - Imports for Main App Views
// These are needed to skip login when bots are already configured

// MARK: - 1. 配置与常量 (Configuration)

struct Theme {
    static let background = Color.black
    static let text = Color.white
    // 粒子颜色：从深灰到浅灰
    static let particleColors: [Color] = [
        Color(white: 0.15),
        Color(white: 0.25),
        Color(white: 0.35),
        Color(white: 0.50)
    ]
    static let blurMaterial: Material = .ultraThin
}

enum LoginState {
    case idle       // 闲置/游走
    case converting // 登录成功：汇聚（黑洞螺旋）
    case exploding  // 爆炸（光芒吞噬）
    case completed  // 完成
}

// MARK: - 2. 粒子模型 (Particle Model)

struct Particle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var color: Color
    var opacity: Double

    // 动画控制
    var delay: Double = 0.0
    var isAbsorbed: Bool = false
    var angle: Double = 0.0 // 用于螺旋运动计算
    var distToCenter: Double = 0.0 // 记录距离
}

// MARK: - 3. 粒子引擎 (Particle Engine)

class ParticleEngine: ObservableObject {
    @Published var particles: [Particle] = []
    @Published var loginState: LoginState = .idle
    @Published var centralOrbRadius: CGFloat = 0.0 // 中心光球大小
    @Published var time: Double = 0.0 // 用于驱动星云旋转

    private var displayLink: AnyCancellable?
    private let particleCount = 150 // 增加粒子数量
    private var screenSize: CGSize = .zero
    private var startTime: Date?

    func setup(size: CGSize) {
        self.screenSize = size
        guard particles.isEmpty else { return }

        for _ in 0..<particleCount {
            let p = Particle(
                position: CGPoint(
                    x: CGFloat.random(in: 0...size.width),
                    y: CGFloat.random(in: 0...size.height)
                ),
                velocity: CGVector(
                    dx: CGFloat.random(in: -0.2...0.2), // 初始速度更慢
                    dy: CGFloat.random(in: -0.2...0.2)
                ),
                radius: CGFloat.random(in: 1.5...3.5),
                color: Theme.particleColors.randomElement()!,
                opacity: Double.random(in: 0.2...0.6),
                delay: Double.random(in: 0.0...1.5) // 延迟范围拉大，过程更漫长
            )
            particles.append(p)
        }
        startLoop()
    }

    private func startLoop() {
        displayLink = Timer.publish(every: 1/60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.update() }
    }

    private func update() {
        let center = CGPoint(x: screenSize.width * 0.5, y: screenSize.height * 0.5)
        time += 0.01 // 时间推进

        switch loginState {
        case .idle:
            for i in particles.indices {
                var p = particles[i]
                p.position.x += p.velocity.dx
                p.position.y += p.velocity.dy

                // 边界反弹
                if p.position.x < 0 || p.position.x > screenSize.width { p.velocity.dx *= -1 }
                if p.position.y < 0 || p.position.y > screenSize.height { p.velocity.dy *= -1 }
                particles[i] = p
            }

        case .converting:
            guard let start = startTime else { return }
            let elapsed = Date().timeIntervalSince(start)

            for i in particles.indices {
                var p = particles[i]
                if p.isAbsorbed { continue }

                if elapsed < p.delay {
                    // 未启动时依旧轻微漂浮
                    p.position.x += p.velocity.dx * 0.5
                    p.position.y += p.velocity.dy * 0.5
                } else {
                    // === 径向汇聚逻辑 (恢复直线吸入) ===
                    let dx = center.x - p.position.x
                    let dy = center.y - p.position.y
                    let currentDist = sqrt(dx*dx + dy*dy)

                    if currentDist < 15 {
                        p.isAbsorbed = true
                        // 光球缓慢生长 (Max 60)
                        if centralOrbRadius < 60 {
                            centralOrbRadius += 0.3
                        }
                    } else {
                        // 1. 径向吸力 (Suction): 距离越近吸力越大
                        // 基础速度很慢，只有靠近了才快
                        let suctionSpeed: CGFloat = 2.0 + (500.0 / (currentDist + 10.0)) * 0.2

                        // 简单的直线移动比例
                        let ratio = suctionSpeed / currentDist
                        p.position.x += dx * ratio
                        p.position.y += dy * ratio

                        // 粒子变亮
                        p.opacity = min(p.opacity + 0.02, 1.0)
                    }
                }
                particles[i] = p
            }

            // 检查是否所有粒子被吸收
            if particles.allSatisfy({ $0.isAbsorbed }) {
                // 确保光球生长到足够大再爆炸
                if centralOrbRadius >= 50 {
                    withAnimation(.easeInOut(duration: 2.0)) { // 爆炸过程更慢
                        loginState = .exploding
                    }
                } else {
                    // 强制补齐光球大小
                    centralOrbRadius += 1.0
                }
            }

        case .exploding:
            // === 宇宙大爆炸 (光芒吞噬) ===
            // 光球指数级膨胀，直到填满屏幕
            let maxRadius = max(screenSize.width, screenSize.height) * 1.2

            if centralOrbRadius < maxRadius {
                // 加速膨胀公式
                centralOrbRadius = centralOrbRadius * 1.06 + 2.0
            } else {
                // 屏幕全白后，切换完成状态
                if centralOrbRadius >= maxRadius {
                    // 稍微延迟一下保持全白状态
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeOut(duration: 0.7)) {
                            self.loginState = .completed
                        }
                    }
                }
            }

        case .completed:
            break
        }
    }

    func triggerLoginSuccess() {
        startTime = Date()
        withAnimation(.easeInOut(duration: 1.0)) {
            loginState = .converting
        }
    }
}

// MARK: - 4. 粒子画布 (Canvas View)

struct ParticleCanvas: View {
    @ObservedObject var engine: ParticleEngine

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)

            // 1. 绘制普通粒子
            for particle in engine.particles {
                if particle.isAbsorbed || particle.opacity <= 0 { continue }

                let rect = CGRect(
                    x: particle.position.x - particle.radius,
                    y: particle.position.y - particle.radius,
                    width: particle.radius * 2,
                    height: particle.radius * 2
                )
                context.opacity = particle.opacity
                context.fill(Path(ellipseIn: rect), with: .color(particle.color))
            }

            // 2. 绘制中心光球 (Converting / Exploding)
            if engine.centralOrbRadius > 0 {
                drawNebulaAndCore(context: context, center: center, radius: engine.centralOrbRadius)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    // 将复杂绘制逻辑提取为独立函数，解决编译器超时问题
    private func drawNebulaAndCore(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let r = radius
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r*2, height: r*2)

        var orbContext = context
        // 爆炸时不降低透明度，而是保持纯白覆盖
        orbContext.opacity = 1.0

        if engine.loginState == .exploding {
            // 爆炸阶段：纯白扩散
            orbContext.fill(Path(ellipseIn: rect), with: .color(.white))
        } else {
            // 汇聚阶段：只绘制 3D 核心球体 (Radial Gradient)，移除星云

            // B. 绘制3D核心球体 (Radial Gradient)
            // 高光点偏向左上角，模拟立体感
            let gradient = Gradient(stops: [
                .init(color: .white, location: 0.1),       // 高光核心
                .init(color: .white.opacity(0.8), location: 0.4),
                .init(color: .white.opacity(0.0), location: 1.0) // 边缘虚化
            ])

            // 稍微放大一点绘制区域以容纳模糊边缘
            let coreRect = rect.insetBy(dx: -5, dy: -5)

            // 计算高光点位置 (左上角偏移)
            let highlightCenter = CGPoint(
                x: coreRect.midX - coreRect.width * 0.2,
                y: coreRect.midY - coreRect.height * 0.2
            )

            orbContext.fill(
                Path(ellipseIn: coreRect),
                with: .radialGradient(
                    gradient,
                    center: highlightCenter, // 使用具体的坐标点
                    startRadius: 0,
                    endRadius: r * 1.5
                )
            )
        }
    }
}

// MARK: - 5. 自定义按钮组件

enum ButtonIconType {
    case system(String)
    case asset(String)
}

struct GlassButton: View {
    let icon: ButtonIconType
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 固定 24x24 图标容器，确保所有图标对齐
                ZStack {
                    switch icon {
                    case .system(let name):
                        Image(systemName: name)
                            .font(.system(size: name == "envelope.fill" ? 18 : 20))  // 邮件图标更小
                            .frame(width: 22, height: 22)
                    case .asset(let name):
                        Image(name)
                            .resizable()
                            .renderingMode(.template)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)  // Asset 图标稍小
                    }
                }
                .frame(width: 24, height: 24)
                .foregroundColor(.white)

                Text(text)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                ZStack {
                    Rectangle().fill(Theme.blurMaterial)
                    Color.white.opacity(0.1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.6),
                                .white.opacity(0.2),
                                .white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Main View

struct LoginView: View {
    @StateObject private var particleEngine = ParticleEngine()
    @ObservedObject private var authService = AuthService.shared
    @EnvironmentObject var homeViewModel: HomeViewModel
    @State private var isAlreadyLoggedIn: Bool = false
    @State private var showServerConfig: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Layer 1: Background Animation
                ParticleCanvas(engine: particleEngine)
                    .onAppear {
                        particleEngine.setup(size: geo.size)
                        // 已登录时快速跳过动画
                        if authService.isAuthenticated {
                            isAlreadyLoggedIn = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    particleEngine.loginState = .completed
                                }
                            }
                        }
                    }
                    .onChange(of: geo.size) { _, newSize in
                        particleEngine.setup(size: newSize)
                    }
                    // OAuth 成功 → 播放粒子动画
                    .onChange(of: authService.isAuthenticated) { _, isAuth in
                        if isAuth && particleEngine.loginState == .idle {
                            particleEngine.triggerLoginSuccess()
                        } else if !isAuth {
                            // 退出登录 → 回到登录页
                            particleEngine.loginState = .idle
                            isAlreadyLoggedIn = false
                        }
                    }
                    .onOpenURL { url in
                        handleOAuthCallback(url)
                    }

                // Layer 2: App Logo
                if particleEngine.loginState == .idle {
                    VStack {
                        Spacer()
                            .frame(height: geo.size.height * 0.2)
                        appLogo
                        Spacer()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                }

                // Layer 3: Login Content (底部卡片)
                if particleEngine.loginState == .idle {
                    loginContentLayer
                        .preferredColorScheme(.dark)
                        .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                }

                // Layer 4: Main App Content (爆炸白屏后淡入)
                if particleEngine.loginState == .completed {
                    MainAppView()
                        .transition(.opacity.animation(.easeIn(duration: isAlreadyLoggedIn ? 0.3 : 1.5)))
                }

                // Layer 5: Settings button (top-right corner, visible on login screen)
                if particleEngine.loginState == .idle {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: { showServerConfig = true }) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundColor(.white.opacity(0.45))
                                    .padding(16)
                            }
                        }
                        Spacer()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                }
            }
        }
        .sheet(isPresented: $showServerConfig) {
            ServerConfigSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
    }

    var loginContentLayer: some View {
        VStack {
            Spacer()
            VStack(spacing: 30) {
                headerText
                loginButtonsGroup
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 50)
            .padding(.top, 40) // 增加一点顶部间距
            .background(
                ZStack {
                    Rectangle()
                        .fill(Theme.blurMaterial)
                        .opacity(0.85)

                    LinearGradient(
                        colors: [.black.opacity(0.1), .clear],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                }
                .ignoresSafeArea()
            )
        }
    }

    var appLogo: some View {
        Image("ContextGoLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 180, height: 180)
            .shadow(color: .white.opacity(0.3), radius: 25, x: 0, y: 10)
            .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 5)
    }

    var headerText: some View {
        Text("Sign in to access your workspace")
            .font(.system(size: 16, weight: .regular))
            .foregroundColor(.white.opacity(0.6))
    }

    var loginButtonsGroup: some View {
        VStack(spacing: 12) {
            GlassButton(icon: ButtonIconType.asset("logo_github"), text: "Continue with GitHub") {
                startOAuth(provider: "github")
            }
            GlassButton(icon: ButtonIconType.asset("logo_google"), text: "Continue with Google") {
                startOAuth(provider: "google")
            }
        }
    }

    // MARK: - Core OAuth

    @State private var authSession: ASWebAuthenticationSession?

    private func startOAuth(provider: String) {
        let ep = CoreConfig.shared.endpoint.trimmingCharacters(in: .whitespaces)
        let base = ep.hasSuffix("/") ? ep : ep + "/"
        guard let url = URL(string: base + "api/oauth/\(provider)") else { return }

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "contextgo"
        ) { callbackURL, error in
            if let callbackURL = callbackURL {
                handleOAuthCallback(callbackURL)
            }
        }
        session.presentationContextProvider = WindowProvider.shared
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    private func handleOAuthCallback(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "contextgo" || scheme == "ctxgo"),
              url.host == "auth" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let token = components?.queryItems?.first(where: { $0.name == "token" })?.value else {
            let error = components?.queryItems?.first(where: { $0.name == "error" })?.value ?? "missing token"
            print("[OAuth] Callback without token: \(error), url: \(url.absoluteString)")
            return
        }
        Task { @MainActor in
            CoreConfig.shared.saveJWT(token)
            await AuthService.shared.checkAuthentication()
        }
    }
}

// MARK: - Preview

#Preview {
    LoginView()
}
