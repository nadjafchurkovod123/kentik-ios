import UIKit

/// Домашний экран пустой вкладки: обои с акулой в короне, как на десктопе.
final class HomeView: UIView {

    private let imageView = UIImageView(image: UIImage(named: "Wallpaper"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        accessibilityIdentifier = "homeView"

        // Обои на чёрном фоне: целиком вписываем, чтобы акула с короной не обрезалась в портрете.
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }
}
