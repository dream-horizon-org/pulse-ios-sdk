import UIKit

class SecondViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Second Screen"
        view.backgroundColor = .systemIndigo

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
        label.text = "SecondViewController"
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        stackView.addArrangedSubview(label)

        let hint = UILabel()
        hint.text = "screen.name is now \"SecondViewController\"\nlast.screen.name is \"MainViewController\""
        hint.font = .systemFont(ofSize: 14)
        hint.textColor = .white.withAlphaComponent(0.8)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        stackView.addArrangedSubview(hint)

        let pushButton = UIButton(type: .system)
        pushButton.setTitle("Push Third Screen →", for: .normal)
        pushButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        pushButton.backgroundColor = .white
        pushButton.setTitleColor(.systemIndigo, for: .normal)
        pushButton.layer.cornerRadius = 8
        pushButton.addTarget(self, action: #selector(pushThirdScreen), for: .touchUpInside)
        stackView.addArrangedSubview(pushButton)

        pushButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        pushButton.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    @objc private func pushThirdScreen() {
        navigationController?.pushViewController(ThirdViewController(), animated: true)
    }
}
