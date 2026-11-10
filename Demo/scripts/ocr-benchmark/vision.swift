import AppKit
import CoreImage
import CoreML
import Foundation
import Vision

func emit(_ object: [String:Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}
let args = CommandLine.arguments
let directory = URL(fileURLWithPath: args[2], isDirectory: true)
if args[1] == "generate" {
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let samples: [(String,String,String,String)] = [
        ("zh-hans","zh-Hans","PingFang SC","项目环境配置管理\n服务器地址和凭证保存在本机\n临时授权到期后自动失效"),
        ("zh-hant","zh-Hant","PingFang TC","專案環境設定管理\n伺服器位址和憑證保存在本機\n臨時授權到期後自動失效"),
        ("english","en-US","Helvetica","Project environment settings\nCredentials stay on this Mac\nTemporary access expires in 7 days"),
        ("japanese","ja-JP","Hiragino Sans","プロジェクトの環境設定\n認証情報はこのMacに保存\n一時アクセスは7日後に失効"),
        ("spanish","es-ES","Helvetica","Configuración del proyecto\nLas credenciales están en este Mac\nEl acceso temporal vence en 7 días"),
        ("turkish","tr-TR","Helvetica","Proje ortamı yapılandırması\nKimlik bilgileri bu Mac'te saklanır\nGeçici erişim 7 gün sonra sona erer"),
        ("code","en-US","Menlo","PORT=3000\nAPI_BASE_URL=https://example.com\nexport const retries = 3;")
    ]
    var manifest: [[String:Any]] = []
    for (name,language,fontName,text) in samples {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1000,pixelsHigh:360,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill();NSRect(x:0,y:0,width:1000,height:360).fill()
        let font = NSFont(name:fontName,size:34) ?? NSFont.systemFont(ofSize:34)
        for (lineIndex,line) in text.components(separatedBy:"\n").enumerated() {
            (line as NSString).draw(at:NSPoint(x:42,y:260-lineIndex*72),withAttributes:[.font:font,.foregroundColor:NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let clean=directory.appendingPathComponent(name+".png")
        try bitmap.representation(using:.png,properties:[:])!.write(to:clean)
        manifest.append(["id":name,"language":language,"file":clean.lastPathComponent,"text":text,"font":font.fontName,"kind":"clean synthetic printed text"])
        if ["zh-hans","english","japanese"].contains(name) {
            let input=CIImage(bitmapImageRep:bitmap)!
            let blurred=input.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1.25]).cropped(to:input.extent)
            let image=CIContext(options:[.useSoftwareRenderer:true]).createCGImage(blurred,from:input.extent)!
            let nameBlur=name+"-blur";let file=directory.appendingPathComponent(nameBlur+".png")
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:file)
            manifest.append(["id":nameBlur,"language":language,"file":file.lastPathComponent,"text":text,"font":font.fontName,"kind":"synthetic Gaussian blur radius 1.25"])
        }
    }
    try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("manifest.json"))
    emit(["fixtures":manifest.count]);exit(0)
}
let fixtures = try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("manifest.json"))) as! [[String:Any]]
let compat=args[1] == "compat"
for fixture in fixtures {
    let start=Date()
    do {
        let request=VNRecognizeTextRequest()
        if compat {
            request.revision=2
            for (stage,devices) in try request.supportedComputeStageDevices {
                if let cpu=devices.first(where:{ if case .cpu = $0 { return true };return false }) { request.setComputeDevice(cpu,for:stage) }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection=true
        request.automaticallyDetectsLanguage=true
        let supported=try request.supportedRecognitionLanguages()
        request.recognitionLanguages=["zh-Hans","zh-Hant","en-US","ja-JP","es-ES"].filter{supported.contains($0)}
        try VNImageRequestHandler(url:directory.appendingPathComponent(fixture["file"] as! String)).perform([request])
        let text=(request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n")
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        emit(["id":fixture["id"]!,"engine":compat ? "vision-revision2-cpu":"vision-production","text":text,"seconds":Date().timeIntervalSince(start),"peak_rss_bytes":usage.ru_maxrss,"revision":request.revision,"supported_languages":supported,"ok":true])
    } catch {
        emit(["id":fixture["id"]!,"engine":compat ? "vision-revision2-cpu":"vision-production","seconds":Date().timeIntervalSince(start),"ok":false,"error":String(describing:error)])
    }
}
