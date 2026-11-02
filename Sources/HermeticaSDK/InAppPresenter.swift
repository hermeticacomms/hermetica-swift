#if os(iOS)
    import UIKit

    /// The built-in renderer: one message at a time in its own window, above the app.
    final class InAppPresenter {
        static let shared = InAppPresenter()
        private var window: UIWindow?
        private var pending: [InAppMessage] = []

        /// Main thread.
        func show(_ m: InAppMessage) {
            guard window == nil else { pending.append(m); return }
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            w.passthrough = m.layout == .bannerTop || m.layout == .bannerBottom
            w.rootViewController = InAppViewController(message: m) { [weak self] button in self?.finish(m, button) }
            w.isHidden = false
            window = w
            Hermetica.core?.reportInApp(m, .impression, button: nil)
        }

        /// `button` nil = closed with the close button.
        private func finish(_ m: InAppMessage, _ button: InAppButton?) {
            window?.isHidden = true
            window = nil
            if let button { Hermetica.performInAppAction(button, message: m) } else { Hermetica.core?.reportInApp(m, .dismiss, button: nil) }
            if !pending.isEmpty { show(pending.removeFirst()) }
        }
    }

    /// Banners leave the rest of the screen usable: touches outside the card fall through to the app.
    final class PassthroughWindow: UIWindow {
        var passthrough = false
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let v = super.hitTest(point, with: event)
            return passthrough && v === rootViewController?.view ? nil : v
        }
    }

    final class InAppViewController: UIViewController {
        private let m: InAppMessage
        private let done: (InAppButton?) -> Void

        init(message: InAppMessage, done: @escaping (InAppButton?) -> Void) {
            m = message
            self.done = done
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { return nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            let s = m.style
            let banner = m.layout == .bannerTop || m.layout == .bannerBottom
            view.backgroundColor = banner ? .clear : UIColor(white: 0, alpha: 0.5)

            let card = UIView()
            card.backgroundColor = UIColor(hermeticaHex: s.background) ?? .white
            card.layer.cornerRadius = banner || m.layout == .fullscreen ? 0 : CGFloat(s.radius)
            if m.layout == .bottomSheet { card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] }
            card.accessibilityViewIsModal = !banner
            card.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(card)

            let stack = UIStackView(arrangedSubviews: m.content.blocks.compactMap(blockView))
            stack.axis = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            let scroll = UIScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)
            card.addSubview(scroll)

            let g = card.safeAreaLayoutGuide
            let fit = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
            fit.priority = .defaultHigh  // grow with the content until the card hits its maximum height
            NSLayoutConstraint.activate(
                [
                    stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                    stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                    stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                    stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                    stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                    scroll.topAnchor.constraint(equalTo: g.topAnchor, constant: s.dismissible ? 36 : 20),
                    scroll.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -20),
                    scroll.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
                    scroll.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
                    fit,
                ] + placement(card))

            if s.dismissible {
                let x = UIButton(type: .system)
                x.setTitle("\u{00D7}", for: .normal)
                x.titleLabel?.font = .systemFont(ofSize: 26)
                x.tintColor = UIColor(hermeticaHex: s.textColor) ?? .label
                x.accessibilityLabel = "Close"
                x.addTarget(self, action: #selector(close), for: .touchUpInside)
                x.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(x)
                NSLayoutConstraint.activate([x.topAnchor.constraint(equalTo: g.topAnchor, constant: 4), x.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -8)])
            }
            UIAccessibility.post(notification: .screenChanged, argument: card)
        }

        private func placement(_ card: UIView) -> [NSLayoutConstraint] {
            let v = view.safeAreaLayoutGuide
            let edges = [card.leadingAnchor.constraint(equalTo: view.leadingAnchor), card.trailingAnchor.constraint(equalTo: view.trailingAnchor)]
            switch m.layout {
            case .fullscreen:
                return edges + [card.topAnchor.constraint(equalTo: view.topAnchor), card.bottomAnchor.constraint(equalTo: view.bottomAnchor)]
            case .bannerTop:
                return edges + [card.topAnchor.constraint(equalTo: view.topAnchor), card.heightAnchor.constraint(lessThanOrEqualTo: v.heightAnchor, multiplier: 0.5)]
            case .bannerBottom:
                return edges + [card.bottomAnchor.constraint(equalTo: view.bottomAnchor), card.heightAnchor.constraint(lessThanOrEqualTo: v.heightAnchor, multiplier: 0.5)]
            case .bottomSheet:
                return edges + [card.bottomAnchor.constraint(equalTo: view.bottomAnchor), card.heightAnchor.constraint(lessThanOrEqualTo: v.heightAnchor, multiplier: 0.9)]
            case .modal:
                let width = card.widthAnchor.constraint(equalToConstant: 420)
                width.priority = .defaultHigh
                return [
                    card.centerXAnchor.constraint(equalTo: view.centerXAnchor), card.centerYAnchor.constraint(equalTo: view.centerYAnchor), width,
                    card.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 24),
                    card.heightAnchor.constraint(lessThanOrEqualTo: v.heightAnchor, multiplier: 0.85),
                ]
            }
        }

        private func blockView(_ b: InAppBlock) -> UIView? {
            let s = m.style
            let text = UIColor(hermeticaHex: s.textColor) ?? .label
            switch b.type {
            case .heading, .text:
                let l = UILabel()
                l.text = b.text
                l.numberOfLines = 0
                l.textColor = text
                l.font = b.type == .heading ? UIFont.preferredFont(forTextStyle: .title3).withBold() : UIFont.preferredFont(forTextStyle: .body)
                l.adjustsFontForContentSizeCategory = true
                if b.type == .heading { l.accessibilityTraits = .header }
                return l
            case .image:
                guard let raw = b.url, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                let iv = UIImageView()
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = min(CGFloat(s.radius), 12)
                iv.isAccessibilityElement = !(b.alt ?? "").isEmpty
                iv.accessibilityLabel = b.alt
                iv.heightAnchor.constraint(equalToConstant: 160).isActive = true
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = UIImage(data: data) else { return }
                    DispatchQueue.main.async { iv.image = img }
                }.resume()
                return iv
            case .buttons:
                let row = UIStackView(arrangedSubviews: (b.buttons ?? []).map { button($0, accent: UIColor(hermeticaHex: s.accentColor) ?? .systemBlue) })
                row.axis = (b.buttons?.count ?? 0) > 2 ? .vertical : .horizontal
                row.spacing = 8
                row.distribution = .fillEqually
                return row
            case .unknown:
                return nil
            }
        }

        private func button(_ b: InAppButton, accent: UIColor) -> UIButton {
            let primary = b.style != "secondary"
            let x = UIButton(type: .system)
            x.setTitle(b.label, for: .normal)
            x.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            x.titleLabel?.adjustsFontForContentSizeCategory = true
            x.setTitleColor(primary ? .white : accent, for: .normal)
            x.backgroundColor = primary ? accent : .clear
            x.layer.borderColor = accent.cgColor
            x.layer.borderWidth = 1
            x.layer.cornerRadius = min(CGFloat(m.style.radius), 10)
            x.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
            x.onTap { [weak self] in self?.done(b) }
            return x
        }

        @objc private func close() { done(nil) }
    }

    private extension UIButton {
        /// A closure target for iOS 13 (UIAction handlers on buttons need iOS 14).
        func onTap(_ handler: @escaping () -> Void) {
            let t = ClosureTarget(handler)
            objc_setAssociatedObject(self, &ClosureTarget.key, t, .OBJC_ASSOCIATION_RETAIN)
            addTarget(t, action: #selector(ClosureTarget.fire), for: .touchUpInside)
        }
    }

    private final class ClosureTarget: NSObject {
        static var key = 0
        let handler: () -> Void
        init(_ h: @escaping () -> Void) { handler = h }
        @objc func fire() { handler() }
    }

    private extension UIFont {
        func withBold() -> UIFont { fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? self }
    }

    extension UIColor {
        /// "#rgb", "#rrggbb" or "#rrggbbaa".
        convenience init?(hermeticaHex s: String) {
            var h = s.trimmingCharacters(in: .whitespaces)
            if h.hasPrefix("#") { h.removeFirst() }
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
            let rgb = h.count == 8 ? v >> 8 : v
            let a = h.count == 8 ? CGFloat(v & 0xff) / 255 : 1
            self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: a)
        }
    }
#endif
