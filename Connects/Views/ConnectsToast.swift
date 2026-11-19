import UIKit

/// Lightweight translucent toast bubble (iOS 12+).
enum ConnectsToast {
    private static var activeToast: UIView?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, in host: UIView, duration: TimeInterval = 1.35) {
        hideWork?.cancel()
        activeToast?.removeFromSuperview()

        let c = DSTheme.c
        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = c.surface.withAlphaComponent(0.96)
        bubble.layer.cornerRadius = 14
        bubble.layer.borderWidth = 1 / UIScreen.main.scale
        bubble.layer.borderColor = c.border.cgColor
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.18
        bubble.layer.shadowRadius = 10
        bubble.layer.shadowOffset = CGSize(width: 0, height: 3)
        bubble.clipsToBounds = false
        bubble.isUserInteractionEnabled = false
        bubble.alpha = 0

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = c.textPrimary
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 2
        bubble.addSubview(label)

        host.addSubview(bubble)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),

            bubble.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            bubble.centerYAnchor.constraint(equalTo: host.centerYAnchor, constant: -36),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.72),
            bubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])
        host.bringSubviewToFront(bubble)
        activeToast = bubble

        UIView.animate(withDuration: 0.18) {
            bubble.alpha = 1
        }

        let work = DispatchWorkItem {
            UIView.animate(withDuration: 0.22, animations: {
                bubble.alpha = 0
            }, completion: { _ in
                if activeToast === bubble {
                    activeToast = nil
                }
                bubble.removeFromSuperview()
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
