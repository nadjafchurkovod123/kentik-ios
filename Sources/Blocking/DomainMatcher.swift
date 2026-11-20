import Foundation

/// Домены для выключателя щита «на сайте»: приближение eTLD+1 (регистрируемый домен).
///
/// Полный Public Suffix List в приложение не тащим: берём последние две метки, а для
/// известных многоуровневых суффиксов (co.uk, com.ru, github.io, ucoz.ru…) — три.
/// Так «m.kinogo.ru», «www.kinogo.ru» и «kinogo.ru» — один сайт.
enum DomainMatcher {

    /// Суффиксы из двух и более меток, под которыми регистрируют сайты.
    static let multiLabelSuffixes: Set<String> = [
        // Великобритания, Австралия, Новая Зеландия, Азия
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "org.nz", "net.nz", "ac.nz", "govt.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "gr.jp",
        "co.kr", "or.kr", "ne.kr", "re.kr", "go.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "org.tw", "net.tw", "com.hk", "org.hk", "net.hk",
        "com.sg", "com.my", "com.ph", "com.vn", "com.pk", "co.id", "or.id", "web.id",
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in",
        "co.th", "in.th", "ac.th", "go.th",
        "co.il", "org.il", "com.tr", "net.tr", "org.tr", "com.sa", "com.eg",
        // Америка, Африка, Европа
        "com.br", "net.br", "org.br", "com.mx", "com.ar", "com.co", "com.pe", "com.ve",
        "co.za", "org.za", "web.za", "com.ng",
        "com.pl", "net.pl", "org.pl", "com.es", "com.pt", "com.gr", "co.at", "or.at",
        // Рунет и СНГ
        "com.ru", "net.ru", "org.ru", "pp.ru", "msk.ru", "spb.ru", "msk.su", "spb.su",
        "com.ua", "net.ua", "org.ua", "in.ua", "kiev.ua", "kharkov.ua", "od.ua", "lviv.ua",
        "com.by", "net.by", "com.kz", "org.kz", "com.uz", "co.uz", "com.ge", "com.am", "com.az",
        "narod.ru", "ucoz.ru", "ucoz.net", "ucoz.com", "ucoz.ua", "my1.ru", "do.am", "at.ua", "3dn.ru",
        // Хостинги, где у каждого свой поддомен
        "github.io", "gitlab.io", "blogspot.com", "appspot.com", "herokuapp.com", "netlify.app",
        "vercel.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "azurewebsites.net",
        "cloudfront.net", "wordpress.com", "tumblr.com", "glitch.me", "onrender.com", "fly.dev",
    ]

    /// Суффиксы из трёх меток.
    static let threeLabelSuffixes: Set<String> = [
        "s3.amazonaws.com", "compute.amazonaws.com", "elb.amazonaws.com",
    ]

    /// «WWW.Sub.Example.co.uk.» → «example.co.uk». IP-адреса и одиночные имена — как есть.
    static func registrableDomain(of host: String) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        if name.hasPrefix("[") && name.hasSuffix("]") { return name }
        if isIPAddress(name) { return name }
        let labels = name.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard labels.count > 2 else {
            if labels.count == 2, labels[0] == "www" { return labels[1] }
            return labels.joined(separator: ".")
        }
        let lastThree = labels.suffix(3).joined(separator: ".")
        if threeLabelSuffixes.contains(lastThree) {
            return labels.suffix(min(4, labels.count)).joined(separator: ".")
        }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return lastThree
        }
        return lastTwo
    }

    /// Принадлежит ли хост домену (сам домен или его поддомен).
    static func host(_ host: String, belongsTo domain: String) -> Bool {
        let h = host.lowercased()
        let d = domain.lowercased()
        guard !d.isEmpty else { return false }
        return h == d || h.hasSuffix("." + d)
    }

    static func isIPAddress(_ name: String) -> Bool {
        if name.contains(":") { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), !part.isEmpty, part.allSatisfy(\.isNumber) else { return false }
            return (0...255).contains(value)
        }
    }
}
