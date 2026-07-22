import UIKit

/// Lightweight translucent toast bubble (iOS 12+).
enum ConnectsToast {
    private static var activeToast: UIView?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, in host: UIView, duration: TimeInterval = 1.35) {
        hideWork?.cancel()
        activeToast?.removeFromSuperview()

        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        bubble.layer.cornerRadius = 14
        bubble.clipsToBounds = true
        bubble.isUserInteractionEnabled = false
        bubble.alpha = 0

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = .white
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
