import UIKit

class ThirdViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Third Screen"
        view.backgroundColor = .systemTeal

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40)
        ])

        let label = UILabel()
        label.text = "ThirdViewController"
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        stackView.addArrangedSubview(label)

        let hint = UILabel()
        hint.text = "screen.name is now \"ThirdViewController\"\nlast.screen.name is \"SecondViewController\""
        hint.font = .systemFont(ofSize: 14)
        hint.textColor = .white.withAlphaComponent(0.8)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        stackView.addArrangedSubview(hint)

        let info = UILabel()
        info.text = "Pop back to test screen transitions.\nEach transition updates screen.name\nand last.screen.name on all future signals."
        info.font = .systemFont(ofSize: 13)
        info.textColor = .white.withAlphaComponent(0.6)
        info.textAlignment = .center
        info.numberOfLines = 0
        stackView.addArrangedSubview(info)
    }
}
