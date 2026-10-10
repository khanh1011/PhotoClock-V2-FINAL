import UIKit
import PhotosUI

final class PhotoClockViewController: UIViewController, PHPickerViewControllerDelegate {

    enum OrientationMode: Int { case automatic = 0, portrait = 1, landscape = 2 }

    static var currentOrientationMask: UIInterfaceOrientationMask {
        let mode = OrientationMode(rawValue: UserDefaults.standard.integer(forKey: "orientationMode")) ?? .automatic
        switch mode {
        case .portrait: return .portrait
        case .landscape: return .landscape
        case .automatic: return [.portrait, .landscapeLeft, .landscapeRight]
        }
    }

    private let backgroundImageView = UIImageView()
    private let photoImageView = UIImageView()
    private let dimView = UIView()
    private let clockLabel = UILabel()
    private let dateLabel = UILabel()
    private let controlsContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let chooseButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)

    private var slideshowTimer: Timer?
    private var clockTimer: Timer?
    private var images: [UIImage] = []
    private var currentIndex = 0
    private var randomOrder: [Int] = []
    private var randomOrderPosition = 0
    private var settingsPanel: UIView?
    private var controlsVisible = false
    private var blurTask: DispatchWorkItem?
    private let ciContext = CIContext()

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { Self.currentOrientationMask }

    private var interval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "photoInterval")
        return v > 0 ? v : 30
    }
    private var textSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: "textSize")
        return v > 0 ? v : 84
    }
    private var dateTextSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: "dateTextSize")
        return v > 0 ? v : 22
    }
    private var fontName: String { UserDefaults.standard.string(forKey: "fontName") ?? "System" }
    private var showDate: Bool { UserDefaults.standard.object(forKey: "showDate") == nil ? true : UserDefaults.standard.bool(forKey: "showDate") }
    private var showSeconds: Bool { UserDefaults.standard.bool(forKey: "showSeconds") }
    private var randomPhotos: Bool { UserDefaults.standard.object(forKey: "randomPhotos") == nil ? true : UserDefaults.standard.bool(forKey: "randomPhotos") }
    // 1 = force large layout, 2 = force compact layout, 0 = automatic. Default to large for CarBridge split-screen.
    private var displayMode: Int { UserDefaults.standard.object(forKey: "displayMode") == nil ? 0 : UserDefaults.standard.integer(forKey: "displayMode") }
    private var largeDisplayHeightThreshold: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "largeDisplayHeightThreshold")
        return saved > 0 ? CGFloat(saved) : 250
    }
    private var isLargeDisplay: Bool {
        displayMode == 1 || (displayMode == 0 && view.bounds.height >= largeDisplayHeightThreshold)
    }
    private var imageBlur: CGFloat {
        let v = UserDefaults.standard.double(forKey: "imageBlur")
        return v >= 0 ? CGFloat(v) : 1.2
    }
    private var imageDarkness: CGFloat {
        let v = UserDefaults.standard.double(forKey: "imageDarkness")
        return v >= 0 ? CGFloat(v) : 0.20
    }

    private var textColor: UIColor {
        UIColor(red: CGFloat(UserDefaults.standard.double(forKey: "textR")),
                green: CGFloat(UserDefaults.standard.double(forKey: "textG")),
                blue: CGFloat(UserDefaults.standard.double(forKey: "textB")), alpha: 1)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .unspecified
        setupDefaults()
        setupUI()
        loadPhotos()
        updateClock()
        startTimers()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutUI()
    }

    deinit {
        slideshowTimer?.invalidate()
        clockTimer?.invalidate()
    }

    private func setupDefaults() {
        let d = UserDefaults.standard
        let defaults: [String: Any] = [
            "photoInterval": 30.0, "textSize": 84.0, "dateTextSize": 22.0, "fontName": "System", "imageBlur": 1.2, "imageDarkness": 0.20,
            "showDate": true, "showSeconds": false, "orientationMode": 0, "randomPhotos": true, "displayMode": 0, "largeDisplayHeightThreshold": 250.0,
            "textR": 1.0, "textG": 1.0, "textB": 1.0
        ]
        for (k,v) in defaults where d.object(forKey: k) == nil { d.set(v, forKey: k) }
    }

    private func setupUI() {
        view.backgroundColor = .black

        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.alpha = 0.58
        view.addSubview(backgroundImageView)

        photoImageView.contentMode = .scaleAspectFit
        photoImageView.clipsToBounds = true
        view.addSubview(photoImageView)

        dimView.backgroundColor = .black
        view.addSubview(dimView)

        clockLabel.textAlignment = .center
        clockLabel.adjustsFontSizeToFitWidth = true
        clockLabel.minimumScaleFactor = 0.5
        view.addSubview(clockLabel)

        dateLabel.textAlignment = .center
        dateLabel.numberOfLines = 1
        view.addSubview(dateLabel)

        styleButton(chooseButton, "🖼  Chọn ảnh", #selector(selectPhotos))
        styleButton(settingsButton, "⚙️  Cài đặt", #selector(openSettings))
        controlsContainer.effect = UIBlurEffect(style: traitCollection.userInterfaceStyle == .dark ? .systemMaterialDark : .systemMaterialLight)
        controlsContainer.layer.cornerRadius = 18
        controlsContainer.clipsToBounds = true
        // Start with controls hidden; a screen tap reveals them.
        controlsContainer.alpha = 0
        controlsContainer.contentView.addSubview(chooseButton)
        controlsContainer.contentView.addSubview(settingsButton)
        view.addSubview(controlsContainer)

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleControls)))
        applyAppearance()
    }

    private func styleButton(_ b: UIButton, _ title: String, _ action: Selector) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(traitCollection.userInterfaceStyle == .dark ? .white : .black, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        b.layer.cornerRadius = 12
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    private func layoutUI() {
        backgroundImageView.frame = view.bounds
        photoImageView.frame = view.bounds
        dimView.frame = view.bounds
        dimView.alpha = imageDarkness

        let safe = view.safeAreaInsets
        let width = view.bounds.width
        let height = view.bounds.height
        let landscape = width > height

        let controlHeight: CGFloat = 58
        let controlInset: CGFloat = 18
        let controlsBottom = height - max(safe.bottom, 18)
        controlsContainer.frame = CGRect(
            x: controlInset,
            y: controlsBottom - controlHeight,
            width: max(0, width - controlInset * 2),
            height: controlHeight
        )
        chooseButton.frame = CGRect(x: 8, y: 8, width: max(0, controlsContainer.bounds.width / 2 - 12), height: 42)
        settingsButton.frame = CGRect(x: controlsContainer.bounds.width / 2 + 4, y: 8, width: max(0, controlsContainer.bounds.width / 2 - 12), height: 42)

        // Adaptive CarBridge layout: roomy displays prioritize the photo; compact displays prioritize readability.
        let isLargeDisplay = self.isLargeDisplay
        let top = safe.top + 10

        if isLargeDisplay {
            // Large display: clear photo with time and date at the top.
            photoImageView.alpha = 1
            dimView.alpha = imageDarkness
            let clockHeight: CGFloat = min(76, max(48, height * 0.16))
            // Keep the full date on a single line on large displays too.
            let dateHeight: CGFloat = showDate ? 34 : 0
            let gap: CGFloat = showDate ? 2 : 0
            clockLabel.frame = CGRect(x: 16, y: top, width: width - 32, height: clockHeight)
            dateLabel.frame = CGRect(x: 18, y: clockLabel.frame.maxY + gap, width: width - 36, height: dateHeight)
            clockLabel.font = makeFont(min(textSize, clockHeight / 1.12))
            dateLabel.font = makeFont(min(dateTextSize, dateHeight / 1.15))
            dateLabel.numberOfLines = 1
            dateLabel.adjustsFontSizeToFitWidth = true
            dateLabel.minimumScaleFactor = 0.75
            dateLabel.isHidden = !showDate
            clockLabel.textAlignment = .center
        } else {
            // Compact display: blurred/darkened background and a large HH:mm clock centered.
            photoImageView.alpha = 0
            dimView.alpha = max(imageDarkness, 0.38)
            // Compact display: keep the large clock, with the date on one line underneath.
            dateLabel.isHidden = !showDate
            clockLabel.textAlignment = .center
            let clockHeight = min(height * 0.42, max(68, width * 0.36))
            let clockWidth = max(0, width - 20)
            let dateHeight: CGFloat = showDate ? 28 : 0
            let gap: CGFloat = showDate ? 2 : 0
            let groupHeight = clockHeight + gap + dateHeight
            let groupTop = max(top, (height - groupHeight) / 2 - 4)
            clockLabel.frame = CGRect(
                x: 10,
                y: groupTop,
                width: clockWidth,
                height: clockHeight
            )
            dateLabel.frame = CGRect(
                x: 8,
                y: clockLabel.frame.maxY + gap,
                width: max(0, width - 16),
                height: dateHeight
            )
            clockLabel.font = makeFont(min(max(textSize, width * 0.20), min(width * 0.28, 180)))
            dateLabel.font = makeFont(min(dateTextSize, max(12, dateHeight / 1.15)))
            dateLabel.numberOfLines = 1
            dateLabel.adjustsFontSizeToFitWidth = true
            dateLabel.minimumScaleFactor = 0.75
        }    }

    private func makeFont(_ size: CGFloat) -> UIFont {
        fontName == "System" ? .systemFont(ofSize:size) : (UIFont(name:fontName,size:size) ?? .systemFont(ofSize:size))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            controlsContainer.effect = UIBlurEffect(style: traitCollection.userInterfaceStyle == .dark ? .systemMaterialDark : .systemMaterialLight)
            chooseButton.setTitleColor(traitCollection.userInterfaceStyle == .dark ? .white : .black, for: .normal)
            settingsButton.setTitleColor(traitCollection.userInterfaceStyle == .dark ? .white : .black, for: .normal)
            applyAppearance()
        }
    }

    private func applyAppearance() {
        clockLabel.textColor = textColor
        dateLabel.textColor = textColor.withAlphaComponent(0.95)
        dateLabel.isHidden = !showDate
        dimView.alpha = imageDarkness
        view.setNeedsLayout()
    }

    private func updateClock() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        let isLargeDisplay = self.isLargeDisplay
        f.dateFormat = (isLargeDisplay && showSeconds) ? "HH:mm:ss" : "HH:mm"
        clockLabel.text = f.string(from: Date())
        f.dateFormat = "EEEE, dd/MM/yyyy"
        dateLabel.text = showDate ? f.string(from: Date()) : nil
    }

    private func startTimers() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.updateClock() }
        restartSlideshow()
    }

    private func restartSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval:interval,repeats:true) { [weak self] _ in self?.nextPhoto() }
    }

    private func photosFolder() -> URL {
        let u = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Photos",isDirectory:true)
        try? FileManager.default.createDirectory(at:u,withIntermediateDirectories:true)
        return u
    }

    private func loadPhotos() {
        let urls = (try? FileManager.default.contentsOfDirectory(at:photosFolder(),includingPropertiesForKeys:nil)) ?? []
        let sorted = urls.filter{$0.pathExtension.lowercased()=="jpg"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        images = sorted.compactMap{UIImage(contentsOfFile:$0.path)}
        rebuildRandomOrder()
        showCurrent(false)
    }

    @objc private func selectPhotos() {
        var c = PHPickerConfiguration(photoLibrary:.shared())
        c.filter = .images
        c.selectionLimit = 0
        let p = PHPickerViewController(configuration:c)
        p.delegate = self
        present(p,animated:true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results:[PHPickerResult]) {
        picker.dismiss(animated:true)
        guard !results.isEmpty else { return }
        let folder = photosFolder()
        for u in ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []) where u.pathExtension.lowercased()=="jpg" {
            try? FileManager.default.removeItem(at:u)
        }
        images.removeAll()
        let group = DispatchGroup()
        for (i,r) in results.enumerated() {
            guard r.itemProvider.canLoadObject(ofClass:UIImage.self) else { continue }
            group.enter()
            r.itemProvider.loadObject(ofClass:UIImage.self) { obj,_ in
                defer { group.leave() }
                guard let image = obj as? UIImage, let data=image.jpegData(compressionQuality:0.94) else { return }
                try? data.write(to:folder.appendingPathComponent(String(format:"%04d.jpg",i)),options:.atomic)
            }
        }
        group.notify(queue:.main) {
            self.loadPhotos()
            self.currentIndex = self.randomOrder.first ?? 0
            self.showCurrent(true)
            self.restartSlideshow()
        }
    }

    private func showCurrent(_ animated:Bool) {
        guard !images.isEmpty else { return }
        let image = images[currentIndex]

        if animated {
            UIView.transition(with: photoImageView, duration: 1.2, options: .transitionCrossDissolve) {
                self.photoImageView.image = image
            }
            UIView.transition(with: backgroundImageView, duration: 1.2, options: .transitionCrossDissolve) {
                self.backgroundImageView.image = self.blurredImage(image, radius: 18)
            }
        } else {
            photoImageView.image = image
            backgroundImageView.image = blurredImage(image, radius: 18)
        }
        applyImageEffects(animated: animated)
    }

    private func applyImageEffects(animated: Bool) {
        guard !images.isEmpty else { return }
        let image = images[currentIndex]
        blurTask?.cancel()
        let radius = imageBlur
        var task: DispatchWorkItem?
        task = DispatchWorkItem { [weak self] in
            guard let self = self, let task = task, !task.isCancelled else { return }
            let result = self.blurredImage(image, radius: radius)
            DispatchQueue.main.async {
                guard !task.isCancelled else { return }
                if animated {
                    UIView.transition(with: self.photoImageView, duration: 0.8, options: .transitionCrossDissolve) {
                        self.photoImageView.image = result
                    }
                } else {
                    self.photoImageView.image = result
                }
            }
        }
        blurTask = task
        if let task { DispatchQueue.global(qos: .userInitiated).async(execute: task) }
    }

    private func blurredImage(_ image: UIImage, radius: CGFloat) -> UIImage {
        guard radius > 0, let input = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage?.cropped(to: input.extent),
              let cg = ciContext.createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private func rebuildRandomOrder() {
        guard !images.isEmpty else { randomOrder = []; randomOrderPosition = 0; currentIndex = 0; return }
        randomOrder = Array(images.indices)
        if randomPhotos { randomOrder.shuffle() }
        randomOrderPosition = 0
        currentIndex = randomOrder[0]
    }

    private func nextPhoto() {
        guard images.count > 1 else { return }
        if randomPhotos {
            // Shuffle-bag behavior: each photo appears once per round.
            if randomOrder.isEmpty || randomOrder.count != images.count { rebuildRandomOrder() }
            randomOrderPosition += 1
            if randomOrderPosition >= randomOrder.count {
                let previous = currentIndex
                randomOrder.shuffle()
                if randomOrder.first == previous, randomOrder.count > 1 { randomOrder.swapAt(0, 1) }
                randomOrderPosition = 0
            }
            currentIndex = randomOrder[randomOrderPosition]
        } else {
            currentIndex = (currentIndex + 1) % images.count
        }
        showCurrent(true)
    }

    @objc private func toggleControls() {
        controlsVisible.toggle()
        UIView.animate(withDuration:0.25) {
            self.controlsContainer.alpha = self.controlsVisible ? 1 : 0
        }
        view.setNeedsLayout()
    }

    @objc private func openSettings() {
        let p=UIView()
        p.frame=CGRect(x:12,y:12,width:view.bounds.width-24,height:view.bounds.height-24)
        p.backgroundColor = UIColor { trait in trait.userInterfaceStyle == .dark ? UIColor.secondarySystemBackground.withAlphaComponent(0.98) : UIColor.systemBackground.withAlphaComponent(0.98) }
        p.layer.cornerRadius=24
        p.clipsToBounds=true
        let title=UILabel()
        title.text="PhotoClock • Cài đặt"
        title.textColor = .label
        title.font = .systemFont(ofSize:22,weight:.bold)
        title.textAlignment = .center
        p.addSubview(title)

        let close=UIButton(type:.system)
        close.setTitle("Đóng",for:.normal)
        close.setTitleColor(.label,for:.normal)
        close.addTarget(self,action:#selector(closeSettings),for:.touchUpInside)
        p.addSubview(close)

        let s=UIScrollView()
        p.addSubview(s)
        var y:CGFloat=12

        y=section("Chế độ hiển thị",s,y)
        let modeRow = UIStackView()
        modeRow.axis = .horizontal
        modeRow.distribution = .fillEqually
        modeRow.spacing = 8
        s.addSubview(modeRow)
        modeRow.frame = CGRect(x:18,y:y,width:view.bounds.width-60,height:42)
        let modes:[(String,Int)] = [("Tự động",0),("Màn lớn",1),("Màn nhỏ",2)]
        for (name,value) in modes {
            let b = UIButton(type:.system)
            b.setTitle(name,for:.normal)
            b.titleLabel?.font = .systemFont(ofSize:14,weight:.semibold)
            b.layer.cornerRadius = 10
            b.backgroundColor = displayMode == value ? .systemBlue : UIColor.secondarySystemBackground
            b.setTitleColor(displayMode == value ? .white : .label,for:.normal)
            b.accessibilityIdentifier = String(value)
            b.addTarget(self,action:#selector(displayModeChanged(_:)),for:.touchUpInside)
            modeRow.addArrangedSubview(b)
        }
        y += 54

        y = section("Hiệu chỉnh tự động CarBridge", s, y)
        let currentSize = UILabel()
        currentSize.text = String(format: "Kích thước vùng hiện tại: %.0f × %.0f pt", view.bounds.width, view.bounds.height)
        currentSize.textColor = .secondaryLabel
        currentSize.font = .systemFont(ofSize: 13)
        currentSize.numberOfLines = 2
        s.addSubview(currentSize)
        currentSize.frame = CGRect(x: 24, y: y, width: view.bounds.width - 72, height: 34)
        y += 38

        let thresholdLabel = UILabel()
        thresholdLabel.text = String(format: "Ngưỡng màn lớn: %.0f pt chiều cao", largeDisplayHeightThreshold)
        thresholdLabel.textColor = .label
        thresholdLabel.font = .systemFont(ofSize: 14, weight: .medium)
        thresholdLabel.tag = 8041
        s.addSubview(thresholdLabel)
        thresholdLabel.frame = CGRect(x: 24, y: y, width: view.bounds.width - 72, height: 24)
        y += 24

        let thresholdSlider = UISlider()
        thresholdSlider.minimumValue = 120
        thresholdSlider.maximumValue = 600
        thresholdSlider.value = Float(largeDisplayHeightThreshold)
        thresholdSlider.accessibilityIdentifier = "largeDisplayHeightThreshold"
        thresholdSlider.addTarget(self, action: #selector(displayThresholdChanged(_:)), for: .valueChanged)
        s.addSubview(thresholdSlider)
        thresholdSlider.frame = CGRect(x: 24, y: y, width: view.bounds.width - 72, height: 32)
        y += 40

        let hint = UILabel()
        hint.text = "Chọn Tự động, rồi chỉnh ngưỡng chiều cao để ô chia đôi nhận là màn lớn còn ô nhỏ nhận là màn nhỏ. Ngưỡng được lưu trên iPhone."
        hint.textColor = .secondaryLabel
        hint.font = .systemFont(ofSize: 12)
        hint.numberOfLines = 0
        s.addSubview(hint)
        hint.frame = CGRect(x: 24, y: y, width: view.bounds.width - 72, height: 42)
        y += 48

        y=section("Kích thước chữ giờ",s,y)
        let clockSizeLabel = UILabel()
        clockSizeLabel.text = String(format: "Cỡ chữ giờ: %.0f", textSize)
        clockSizeLabel.textColor = .label
        clockSizeLabel.font = .systemFont(ofSize: 13)
        clockSizeLabel.tag = 8051
        s.addSubview(clockSizeLabel)
        clockSizeLabel.frame = CGRect(x:24,y:y,width:view.bounds.width-72,height:20)
        y += 20
        let slider=UISlider()
        slider.minimumValue=48; slider.maximumValue=150; slider.value=Float(textSize)
        slider.addTarget(self,action:#selector(sizeChanged(_:)),for:.valueChanged)
        s.addSubview(slider); slider.frame=CGRect(x:24,y:y,width:view.bounds.width-72,height:32); y+=42

        y=section("Kích thước chữ ngày",s,y)
        let dateSizeLabel = UILabel()
        dateSizeLabel.text = String(format: "Cỡ chữ ngày: %.0f", dateTextSize)
        dateSizeLabel.textColor = .label
        dateSizeLabel.font = .systemFont(ofSize: 13)
        dateSizeLabel.tag = 8052
        s.addSubview(dateSizeLabel)
        dateSizeLabel.frame = CGRect(x:24,y:y,width:view.bounds.width-72,height:20)
        y += 20
        let dateSlider = UISlider()
        dateSlider.minimumValue = 12
        dateSlider.maximumValue = 36
        dateSlider.value = Float(dateTextSize)
        dateSlider.addTarget(self, action: #selector(dateSizeChanged(_:)), for: .valueChanged)
        s.addSubview(dateSlider)
        dateSlider.frame = CGRect(x:24,y:y,width:view.bounds.width-72,height:32)
        y += 42

        y=section("Độ mờ ảnh",s,y)
        let blurSlider=UISlider()
        blurSlider.minimumValue=0; blurSlider.maximumValue=5; blurSlider.value=Float(imageBlur)
        blurSlider.addTarget(self,action:#selector(blurChanged(_:)),for:.valueChanged)
        s.addSubview(blurSlider); blurSlider.frame=CGRect(x:24,y:y,width:view.bounds.width-72,height:32); y+=52

        y=section("Độ tối ảnh",s,y)
        let darknessSlider=UISlider()
        darknessSlider.minimumValue=0; darknessSlider.maximumValue=0.60; darknessSlider.value=Float(imageDarkness)
        darknessSlider.addTarget(self,action:#selector(darknessChanged(_:)),for:.valueChanged)
        s.addSubview(darknessSlider); darknessSlider.frame=CGRect(x:24,y:y,width:view.bounds.width-72,height:32); y+=52

        y=section("Màu chữ",s,y)
        let cs:[(String,UIColor)]=[
            ("Trắng",.white),("Vàng",.systemYellow),("Xanh dương",.systemBlue),
            ("Xanh ngọc",.systemTeal),("Xanh lá",.systemGreen),("Tím",.systemPurple),
            ("Hồng",.systemPink),("Đỏ",.systemRed),("Cam",.systemOrange),
            ("Tím nhạt",UIColor(red:0.78,green:0.62,blue:1.0,alpha:1)),
            ("Xanh da trời",UIColor(red:0.35,green:0.78,blue:1.0,alpha:1)),("Đen",.black)
        ]
        let rows=UIStackView(); rows.axis = .vertical; rows.distribution = .fillEqually; rows.spacing=7
        s.addSubview(rows); rows.frame=CGRect(x:24,y:y,width:view.bounds.width-72,height:91)
        let selectedColorName = currentColorName()
        for start in stride(from:0,to:cs.count,by:6) {
            let row=UIStackView(); row.axis = .horizontal; row.distribution = .fillEqually; row.spacing=7
            for (n,c) in cs[start..<min(start+6,cs.count)] {
                let b=UIButton(type:.system)
                b.setTitle(n == selectedColorName ? "✓" : "●", for:.normal)
                b.setTitleColor(c,for:.normal)
                b.backgroundColor = n == selectedColorName ? UIColor.white.withAlphaComponent(0.28) : UIColor.white.withAlphaComponent(0.10)
                b.layer.cornerRadius=10
                b.accessibilityIdentifier=n
                b.accessibilityLabel=n
                b.addTarget(self,action:#selector(colorChanged(_:)),for:.touchUpInside)
                row.addArrangedSubview(b)
            }
            rows.addArrangedSubview(row)
        }
        y+=111

        y=section("Font chữ",s,y)
        let fonts=["System","Helvetica Neue","Avenir Next","Georgia","Courier New","Menlo"]
        y=buttonList(fonts,s,y,selected:fontName,selector:#selector(fontChanged(_:)))
        y+=12

        y=section("Ảnh",s,y)
        y=addSwitch("Đổi ảnh ngẫu nhiên",randomPhotos,s,y,#selector(randomPhotosChanged(_:)))
        y+=8

        y=section("Thời gian đổi ảnh",s,y)
        let ints:[(String,Double)]=[("5 giây",5),("10 giây",10),("15 giây",15),("30 giây",30),("1 phút",60),("2 phút",120),("5 phút",300)]
        y=buttonList(ints.map{($0.0,String($0.1))},s,y,selected:String(interval),selector:#selector(intervalChanged(_:)))
        y+=12

        y=section("Hiển thị",s,y)
        y=addSwitch("Hiện ngày",showDate,s,y,#selector(dateChanged(_:)))
        y=addSwitch("Hiện giây",showSeconds,s,y,#selector(secondsChanged(_:)))
        y+=12

        y=section("Hướng màn hình",s,y)
        let currentOrientation = String(UserDefaults.standard.integer(forKey:"orientationMode"))
        y=buttonList([("Tự động","0"),("Dọc","1"),("Ngang","2")],s,y,selected:currentOrientation,selector:#selector(orientationChanged(_:)))

        s.contentSize=CGSize(width:p.bounds.width,height:y+30)
        settingsPanel=p
        view.addSubview(p)
        p.frame=CGRect(x:12,y:12,width:view.bounds.width-24,height:view.bounds.height-24)
        title.frame=CGRect(x:20,y:14,width:view.bounds.width-124,height:38)
        close.frame=CGRect(x:p.bounds.width-78,y:14,width:60,height:38)
        s.frame=CGRect(x:0,y:60,width:p.bounds.width,height:p.bounds.height-60)
        setControls(false)
    }

    private func section(_ t:String,_ s:UIScrollView,_ y:CGFloat)->CGFloat {
        let l=UILabel(); l.text=t; l.textColor = .secondaryLabel; l.font = .systemFont(ofSize:14,weight:.semibold)
        s.addSubview(l); l.frame=CGRect(x:24,y:y,width:view.bounds.width-72,height:24); return y+30
    }

    private func styleOptionButton(_ b:UIButton, title:String, selected:Bool) {
        b.setTitle(selected ? "✓  " + title : "    " + title, for:.normal)
        b.setTitleColor(.label,for:.normal)
        b.contentHorizontalAlignment = .left
        b.titleLabel?.font = .systemFont(ofSize:16, weight:selected ? .semibold : .regular)
        b.backgroundColor = selected ? UIColor.label.withAlphaComponent(0.12) : UIColor.secondarySystemBackground
        b.layer.cornerRadius = 10
        b.layer.borderWidth = selected ? 1 : 0
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityValue = selected ? "selected" : ""
    }

    private func buttonList(_ names:[String],_ s:UIScrollView,_ y:CGFloat,selected:String,selector:Selector)->CGFloat {
        var yy=y
        for n in names {
            let b=UIButton(type:.system)
            styleOptionButton(b,title:n,selected:n == selected)
            b.accessibilityIdentifier=n
            b.addTarget(self,action:selector,for:.touchUpInside)
            s.addSubview(b); b.frame=CGRect(x:24,y:yy,width:view.bounds.width-72,height:38); yy+=42
        }
        return yy
    }

    private func buttonList(_ items:[(String,String)],_ s:UIScrollView,_ y:CGFloat,selected:String,selector:Selector)->CGFloat {
        var yy=y
        for (n,id) in items {
            let b=UIButton(type:.system)
            styleOptionButton(b,title:n,selected:id == selected)
            b.accessibilityIdentifier=id
            b.addTarget(self,action:selector,for:.touchUpInside)
            s.addSubview(b); b.frame=CGRect(x:24,y:yy,width:view.bounds.width-72,height:38); yy+=42
        }
        return yy
    }

    private func currentColorName() -> String {
        let d=UserDefaults.standard
        let r=d.double(forKey:"textR"), g=d.double(forKey:"textG"), b=d.double(forKey:"textB")
        let colors:[(String,CGFloat,CGFloat,CGFloat)]=[
            ("Trắng",1,1,1),("Vàng",1,0.92,0.23),("Xanh dương",0.0,0.48,1.0),
            ("Xanh ngọc",0.0,0.78,0.75),("Xanh lá",0.20,0.78,0.35),("Tím",0.69,0.32,0.87),
            ("Hồng",1.0,0.18,0.33),("Đỏ",1.0,0.23,0.19),("Cam",1.0,0.58,0.0),
            ("Tím nhạt",0.78,0.62,1.0),("Xanh da trời",0.35,0.78,1.0),("Đen",0,0,0)
        ]
        return colors.min { a,c in
            let da=(r-a.1)*(r-a.1)+(g-a.2)*(g-a.2)+(b-a.3)*(b-a.3)
            let dc=(r-c.1)*(r-c.1)+(g-c.2)*(g-c.2)+(b-c.3)*(b-c.3)
            return da < dc
        }?.0 ?? "Trắng"
    }

    private func addSwitch(_ t:String,_ on:Bool,_ s:UIScrollView,_ y:CGFloat,_ sel:Selector)->CGFloat {
        let l=UILabel(); l.text=t; l.textColor = .label; l.font = .systemFont(ofSize:16); s.addSubview(l); l.frame=CGRect(x:24,y:y,width:view.bounds.width-114,height:36)
        let sw=UISwitch(); sw.isOn=on; sw.addTarget(self,action:sel,for:.valueChanged); s.addSubview(sw); sw.frame=CGRect(x:view.bounds.width-98,y:y,width:50,height:32)
        return y+44
    }

    @objc private func displayModeChanged(_ b:UIButton) {
        buttonTapFeedback(b)
        UserDefaults.standard.set(Int(b.accessibilityIdentifier ?? "1") ?? 1, forKey:"displayMode")
        updateClock()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        refreshSettingsPanel()
    }
    @objc private func closeSettings(){settingsPanel?.removeFromSuperview();settingsPanel=nil;setControls(true)}
    @objc private func displayThresholdChanged(_ slider: UISlider) {
        let threshold = CGFloat(slider.value)
        UserDefaults.standard.set(Double(threshold), forKey: "largeDisplayHeightThreshold")
        if let panel = settingsPanel,
           let label = panel.viewWithTag(8041) as? UILabel {
            label.text = String(format: "Ngưỡng màn lớn: %.0f pt chiều cao", threshold)
        }
        updateClock()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
    @objc private func sizeChanged(_ s:UISlider){
        UserDefaults.standard.set(Double(s.value),forKey:"textSize")
        if let label = settingsPanel?.viewWithTag(8051) as? UILabel { label.text = String(format: "Cỡ chữ giờ: %.0f", s.value) }
        view.setNeedsLayout(); view.layoutIfNeeded()
    }
    @objc private func dateSizeChanged(_ s: UISlider) {
        UserDefaults.standard.set(Double(s.value), forKey: "dateTextSize")
        if let label = settingsPanel?.viewWithTag(8052) as? UILabel { label.text = String(format: "Cỡ chữ ngày: %.0f", s.value) }
        view.setNeedsLayout(); view.layoutIfNeeded()
    }
    @objc private func blurChanged(_ s:UISlider){
        UserDefaults.standard.set(Double(s.value),forKey:"imageBlur")
        applyImageEffects(animated:false)
    }
    @objc private func darknessChanged(_ s:UISlider){
        UserDefaults.standard.set(Double(s.value),forKey:"imageDarkness")
        dimView.alpha = CGFloat(s.value)
    }
    @objc private func colorChanged(_ b:UIButton){
        buttonTapFeedback(b)
        let c: UIColor = {
            switch b.accessibilityIdentifier ?? "Trắng" {
            case "Vàng": return .systemYellow
            case "Xanh dương": return .systemBlue
            case "Xanh ngọc": return .systemTeal
            case "Xanh lá": return .systemGreen
            case "Tím": return .systemPurple
            case "Hồng": return .systemPink
            case "Đỏ": return .systemRed
            case "Cam": return .systemOrange
            case "Tím nhạt": return UIColor(red:0.78,green:0.62,blue:1.0,alpha:1)
            case "Xanh da trời": return UIColor(red:0.35,green:0.78,blue:1.0,alpha:1)
            case "Đen": return .black
            default: return .white
            }
        }()
        var r:CGFloat=1,g:CGFloat=1,bl:CGFloat=1,a:CGFloat=1;c.getRed(&r,green:&g,blue:&bl,alpha:&a)
        let d=UserDefaults.standard;d.set(Double(r),forKey:"textR");d.set(Double(g),forKey:"textG");d.set(Double(bl),forKey:"textB");applyAppearance();refreshSettingsPanel()
    }
    @objc private func fontChanged(_ b:UIButton){
        buttonTapFeedback(b)
        UserDefaults.standard.set(b.accessibilityIdentifier ?? "System",forKey:"fontName")
        applyAppearance()
        refreshSettingsPanel()
    }
    @objc private func intervalChanged(_ b:UIButton){
        buttonTapFeedback(b)
        if let v=Double(b.accessibilityIdentifier ?? ""){UserDefaults.standard.set(v,forKey:"photoInterval");restartSlideshow();refreshSettingsPanel()}
    }
    @objc private func dateChanged(_ s:UISwitch){UserDefaults.standard.set(s.isOn,forKey:"showDate");applyAppearance();updateClock()}
    @objc private func randomPhotosChanged(_ s:UISwitch) {
        UserDefaults.standard.set(s.isOn, forKey: "randomPhotos")
        rebuildRandomOrder()
        showCurrent(true)
        refreshSettingsPanel()
    }
    @objc private func secondsChanged(_ s:UISwitch){UserDefaults.standard.set(s.isOn,forKey:"showSeconds");updateClock()}
    @objc private func orientationChanged(_ b:UIButton){
        buttonTapFeedback(b)
        let m=Int(b.accessibilityIdentifier ?? "0") ?? 0
        UserDefaults.standard.set(m,forKey:"orientationMode")
        switch OrientationMode(rawValue:m) ?? .automatic {
        case .portrait: UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue,forKey:"orientation")
        case .landscape: UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue,forKey:"orientation")
        case .automatic: break
        }
        UIViewController.attemptRotationToDeviceOrientation()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.view.setNeedsLayout();self.refreshSettingsPanel()}
    }
    private func buttonTapFeedback(_ button:UIButton) {
        UIView.animate(withDuration:0.08, animations: {
            button.transform = CGAffineTransform(scaleX:0.96, y:0.96)
        }) { _ in
            UIView.animate(withDuration:0.12) { button.transform = .identity }
        }
    }

    private func refreshSettingsPanel() {
        guard let panel = settingsPanel else { return }
        panel.removeFromSuperview()
        settingsPanel=nil
        openSettings()
    }

    private func setControls(_ visible:Bool){
        controlsVisible = visible
        controlsContainer.alpha = visible ? 1 : 0
        view.setNeedsLayout()
    }
}
