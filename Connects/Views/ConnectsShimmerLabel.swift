import UIKit

/// Muted status label with an optional left→right white shimmer (Cursor loading chrome).
final class ConnectsShimmerLabel: UIView {
    private let baseLabel = UILabel()
    private let highlightLabel = UILabel()
    private let gradient = CAGradientLayer()
    private var shimmerEnabled = false

    var font: UIFont {
        get { baseLabel.font }
        set {
            baseLabel.font = newValue
            highlightLabel.font = newValue
            invalidateIntrinsicContentSize()
        }
    }

    var textColor: UIColor {
        get { baseLabel.textColor }
        set { baseLabel.textColor = newValue }
    }

    var highlightColor: UIColor = .white {
        didSet { highlightLabel.textColor = highlightColor }
    }

    var text: String? {
        get { baseLabel.text }
        set {
            let next = newValue
            guard baseLabel.text != next else { return }
            baseLabel.text = next
            highlightLabel.text = next
            accessibilityLabel = next
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    var numberOfLines: Int {
        get { baseLabel.numberOfLines }
        set {
            baseLabel.numberOfLines = newValue
            highlightLabel.numberOfLines = newValue
            invalidateIntrinsicContentSize()
        }
    }

    /// Required for multi-line intrinsic height inside UIStackView.
    var preferredMaxLayoutWidth: CGFloat {
        get { baseLabel.preferredMaxLayoutWidth }
        set {
            guard abs(baseLabel.preferredMaxLayoutWidth - newValue) > 0.5 else { return }
            baseLabel.preferredMaxLayoutWidth = newValue
            highlightLabel.preferredMaxLayoutWidth = newValue
            invalidateIntrinsicContentSize()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        // Avoid double-draw ghosting: never opaque-over-opaque without a valid mask.
        isOpaque = false
        layer.masksToBounds = true
        baseLabel.translatesAutoresizingMaskIntoConstraints = false
        highlightLabel.translatesAutoresizingMaskIntoConstraints = false
        baseLabel.numberOfLines = 1
        highlightLabel.numberOfLines = 1
        highlightLabel.textColor = highlightColor
        highlightLabel.isHidden = true
        highlightLabel.isUserInteractionEnabled = false
        addSubview(baseLabel)
        addSubview(highlightLabel)
        NSLayoutConstraint.activate([
            baseLabel.topAnchor.constraint(equalTo: topAnchor),
            baseLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            baseLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            baseLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlightLabel.topAnchor.constraint(equalTo: baseLabel.topAnchor),
            highlightLabel.leadingAnchor.constraint(equalTo: baseLabel.leadingAnchor),
            highlightLabel.trailingAnchor.constraint(equalTo: baseLabel.trailingAnchor),
            highlightLabel.bottomAnchor.constraint(equalTo: baseLabel.bottomAnchor)
        ])
        gradient.colors = [
            UIColor.clear.cgColor,
            UIColor.white.cgColor,
            UIColor.clear.cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.45, 0.9]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let w = preferredMaxLayoutWidth > 1 ? preferredMaxLayoutWidth : bounds.width
        if numberOfLines != 1, w > 1 {
            return baseLabel.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        }
        return baseLabel.intrinsicContentSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let w = size.width > 1 ? size.width : (preferredMaxLayoutWidth > 1 ? preferredMaxLayoutWidth : bounds.width)
        return baseLabel.sizeThatFits(CGSize(width: max(w, 1), height: .greatestFiniteMagnitude))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard shimmerEnabled else {
            highlightLabel.isHidden = true
            return
        }
        let b = bounds
        guard b.width > 1, b.height > 1 else {
            // Hide highlight until sized — otherwise both labels paint → ghosting.
            highlightLabel.isHidden = true
            return
        }
        gradient.frame = highlightLabel.bounds.isEmpty ? b : highlightLabel.bounds
        if highlightLabel.layer.mask !== gradient {
            highlightLabel.layer.mask = gradient
        }
        highlightLabel.isHidden = false
        restartAnimationIfNeeded()
    }

    /// Enable Cursor-style left→right white sweep on the glyph mask.
    func setShimmerEnabled(_ enabled: Bool) {
        if shimmerEnabled == enabled {
            if enabled { restartAnimationIfNeeded() }
            return
        }
        shimmerEnabled = enabled
        if enabled {
            // Stay hidden until layout assigns a valid mask frame (prevents double text).
            highlightLabel.isHidden = true
            highlightLabel.layer.mask = gradient
            setNeedsLayout()
            layoutIfNeeded()
            let b = bounds
            if b.width > 1, b.height > 1 {
                gradient.frame = highlightLabel.bounds.isEmpty ? b : highlightLabel.bounds
                highlightLabel.isHidden = false
                startAnimation()
            }
        } else {
            gradient.removeAllAnimations()
            highlightLabel.layer.mask = nil
            highlightLabel.isHidden = true
        }
    }

    private func restartAnimationIfNeeded() {
        guard shimmerEnabled else { return }
        guard bounds.width > 1 else { return }
        if gradient.animation(forKey: "connects.shimmer") == nil {
            startAnimation()
        }
    }

    private func startAnimation() {
        gradient.removeAnimation(forKey: "connects.shimmer")
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-0.6, -0.3, 0.0]
        anim.toValue = [1.0, 1.3, 1.6]
        anim.duration = 1.4
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(anim, forKey: "connects.shimmer")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            gradient.removeAllAnimations()
        } else if shimmerEnabled {
            setNeedsLayout()
            DispatchQueue.main.async { [weak self] in
                self?.restartAnimationIfNeeded()
            }
        }
    }
}
