import UIKit

/// Circular context fill indicator with center percent (green arc on a dim track).
final class ContextUsageRingView: UIView {
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let percentLabel = UILabel()
    private var displayedProgress: CGFloat = 0

    var progressColor = UIColor(red: 0.28, green: 0.84, blue: 0.52, alpha: 1) {
        didSet { progressLayer.strokeColor = progressColor.cgColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineCap = .round
        trackLayer.strokeEnd = 1
        layer.addSublayer(trackLayer)

        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        progressLayer.strokeColor = progressColor.cgColor
        layer.addSublayer(progressLayer)

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.textAlignment = .center
        percentLabel.font = UIFont.systemFont(ofSize: 7, weight: .semibold)
        percentLabel.adjustsFontSizeToFitWidth = true
        percentLabel.minimumScaleFactor = 0.7
        percentLabel.text = "0"
        addSubview(percentLabel)
        NSLayoutConstraint.activate([
            percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.72),
            percentLabel.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.55)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme() {
        let c = DSTheme.c
        trackLayer.strokeColor = c.border.withAlphaComponent(0.55).cgColor
        progressLayer.strokeColor = progressColor.cgColor
        percentLabel.textColor = c.textSecondary
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineWidth: CGFloat = max(2, min(bounds.width, bounds.height) * 0.14)
        trackLayer.lineWidth = lineWidth
        progressLayer.lineWidth = lineWidth

        let inset = lineWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: 1.5 * .pi,
            clockwise: true
        ).cgPath
        trackLayer.path = path
        progressLayer.path = path
        progressLayer.strokeEnd = displayedProgress
    }

    func setProgress(_ value: CGFloat, animated: Bool) {
        let clamped = max(0, min(1, value))
        displayedProgress = clamped
        let percent = Int((clamped * 100).rounded())
        percentLabel.text = "\(percent)"
        updateFillColor(for: percent)
        if animated {
            let anim = CABasicAnimation(keyPath: "strokeEnd")
            anim.fromValue = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
            anim.toValue = clamped
            anim.duration = 0.22
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            progressLayer.strokeEnd = clamped
            progressLayer.add(anim, forKey: "strokeEnd")
        } else {
            progressLayer.removeAnimation(forKey: "strokeEnd")
            progressLayer.strokeEnd = clamped
        }
    }

    private func updateFillColor(for percent: Int) {
        if percent >= 75 {
            progressColor = UIColor(red: 0.92, green: 0.32, blue: 0.28, alpha: 1)
        } else if percent >= 50 {
            progressColor = UIColor(red: 0.95, green: 0.68, blue: 0.22, alpha: 1)
        } else {
            progressColor = UIColor(red: 0.28, green: 0.84, blue: 0.52, alpha: 1)
        }
    }
}
