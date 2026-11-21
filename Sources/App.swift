// 와이파이 명당 찾기 · 화면. 흰 바탕, 차가운 회색 선, 강조색 파랑 하나. 알약 모양 없음.
import SwiftUI
import Charts
import AppKit

enum K {
  static let ink = Color(red: 0.11, green: 0.14, blue: 0.19)
  static let sub = Color(red: 0.42, green: 0.47, blue: 0.53)
  static let line = Color(red: 0.89, green: 0.91, blue: 0.93)
  static let soft = Color(red: 0.97, green: 0.98, blue: 0.99)
  static let soft2 = Color(red: 0.93, green: 0.94, blue: 0.96)
  static let accent = Color(red: 0.15, green: 0.39, blue: 0.92)
}

@main
struct WifiSpotApp: App {
  @StateObject private var e = Engine()
  var body: some Scene {
    Window("와이파이 명당 찾기", id: "main") {
      MainView().environmentObject(e).frame(width: 380).fixedSize(horizontal: false, vertical: true).background(Color.white).preferredColorScheme(.light)
    }
    .windowResizability(.contentSize)   // 창 = 내용 크기(글자는 줄이지 않고, 스크롤·빈 공간 없음)
    MenuBarExtra {
      MenuView().environmentObject(e)
    } label: {
      HStack(spacing: 4) {
        Image(nsImage: dot(e.rssi == nil ? NSColor.systemGray : e.score >= 70 ? .systemGreen : e.score >= 45 ? .systemOrange : .systemRed))
        Text(e.rssi == nil ? "–" : "\(e.score)")
      }
    }
    .menuBarExtraStyle(.window)   // 메뉴 대신 작은 흰 패널: 메뉴 줄은 회색으로만 그려져 판정 색이 안 나옴
  }
}

/// 앱 리소스의 SVG(Lucide, ISC). template 으로 읽어 글자색처럼 칠한다
enum Icons {
  static let info: NSImage = {
    let img = Bundle.main.url(forResource: "info", withExtension: "svg").flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "info.circle", accessibilityDescription: "자세히")!
    img.isTemplate = true
    return img
  }()
}

func dot(_ c: NSColor) -> NSImage {
  let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in c.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true }
  img.isTemplate = false
  return img
}

// 창 크기·안쪽 크기는 모두 고정: 너비 380, 높이는 내용 그대로. 비례 축소·크기 조절 없음.

struct MainView: View {
  @EnvironmentObject var e: Engine
  @State private var showDetail = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 머리글 한 줄
      HStack(spacing: 8) {
        Text("와이파이 명당 찾기").font(.system(size: 16, weight: .bold)).foregroundStyle(K.ink).fixedSize()
        if let n = e.ssid {
          Text(n).font(.system(size: 13, weight: .medium)).foregroundStyle(K.accent).lineLimit(1).truncationMode(.middle)
        } else if e.locationDenied && e.rssi != nil {
          Button("와이파이 이름 보기") { e.openLocationSettings() }.buttonStyle(.link).font(.system(size: 12))
        }
        Spacer(minLength: 6)
        Circle().fill(e.tick % 2 == 0 ? K.accent : K.accent.opacity(0.35)).frame(width: 7, height: 7)
        Text("측정 중").font(.system(size: 12)).foregroundStyle(K.sub).fixedSize()
        // '자세히' = Lucide info SVG 아이콘 버튼. 그림 16, 누르는 곳 28×28, 차가운 회색, 툴팁 '자세히'
        Button { showDetail.toggle() } label: {
          Image(nsImage: Icons.info).resizable().interpolation(.high).frame(width: 16, height: 16)
            .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(showDetail ? K.ink : K.sub)
        .help("자세히").accessibilityLabel("자세히")
        .popover(isPresented: $showDetail, arrowEdge: .top) { detail }
      }.frame(height: 24).padding(.bottom, 6)

      VStack(alignment: .leading, spacing: 0) {
        top.padding(.horizontal, 12).padding(.vertical, 10)
        line
        graph.padding(.horizontal, 12).padding(.vertical, 8)
        line
        chips.padding(.horizontal, 12).padding(.vertical, 8)
      }
      .background(Color.white)
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(K.line, lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
  }

  var line: some View { Rectangle().fill(K.line).frame(height: 1) }

  // ── 맨 위: 점수 링 + 한 마디 + 줌·코딩 판정 ──
  var top: some View {
    HStack(alignment: .center, spacing: 12) {
      ZStack {
        // 링은 숫자보다 가볍게(선 5), 끝은 둥글게: 97%일 때 12시의 각진 회색 틈이 깨진 것처럼 보이지 않게
        Circle().stroke(K.line, lineWidth: 5)
        Circle().trim(from: 0, to: CGFloat(e.score) / 100).stroke(scoreColor, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.5), value: e.score)
        Text(e.rssi == nil ? "–" : "\(e.score)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(K.ink).monospacedDigit()
      }.frame(width: 76, height: 76).padding(2).help("지금 자리 점수")
      VStack(alignment: .leading, spacing: 5) {
        Text(scoreWord).font(.system(size: 18, weight: .bold)).foregroundStyle(scoreColor).lineLimit(1)
        verdictLine("줌 수업", e.zoomGrade, e.zoomGrade == .good ? "괜찮아요" : nil, zoomWhy)
        verdictLine("바이브코딩", e.codeGrade, e.codeGrade == .good ? "충분해요" : nil, codeWhy)
      }
      Spacer(minLength: 0)
    }
  }

  // 이름(고정 폭) | 판정(색). 좋으면 한 마디('괜찮아요'), 아니면 등급 + 이유(길면 다음 줄로, 글자는 줄이지 않음). 점(·) 없음
  func verdictLine(_ k: String, _ g: Grade, _ okWord: String?, _ why: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(k).foregroundStyle(K.ink).fontWeight(.semibold).frame(width: 74, alignment: .leading)
      if let ok = okWord {
        Text(ok).foregroundStyle(g.color).fontWeight(.bold)
      } else {
        (Text(g.word).fontWeight(.bold) + Text("  ") + Text(why)).foregroundStyle(g.color).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }.font(.system(size: 14))
  }
  var zoomWhy: String {
    if e.lossGrade != .good { return e.lossWhy }   // 손실 기준은 Engine
    if (e.jitter ?? 0) >= 30 { return "소리가 흔들려요" }
    if (e.latency ?? 0) >= 100 { return "반응이 느려요" }
    return e.rssi == nil ? "연결이 없어요" : "신호가 약해요"
  }
  var codeWhy: String {
    if e.lossGrade != .good { return e.lossWhy }   // 손실 기준은 Engine
    if (e.codeMs ?? e.latency ?? 0) >= 150 { return "반응이 느려요" }
    return e.rssi == nil ? "연결이 없어요" : "신호가 약해요"
  }
  /// 맨 위 한 마디·링 색은 점수와 두 판정 중 나쁜 쪽에 맞춘다(점수는 높은데 '피하세요'가 같이 뜨지 않게)
  var overall: Grade {
    if e.rssi == nil { return .bad }
    let byScore: Grade = e.score >= 70 ? .good : e.score >= 45 ? .fair : .bad
    return [byScore, e.zoomGrade, e.codeGrade].min { $0.rawValue < $1.rawValue }!
  }
  var scoreColor: Color { e.rssi == nil ? K.sub : overall.color }
  var scoreWord: String { e.rssi == nil ? "연결 없음" : overall == .good ? "여기 좋아요" : overall == .fair ? "그럭저럭이에요" : "다른 자리를 찾아보세요" }

  // ── 최근 60초 신호(눈금·범례 없음, 구간만 연한 바탕) ──
  var graph: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("최근 1분 신호").font(.system(size: 12)).foregroundStyle(K.sub)
      Chart {
        RectangleMark(yStart: .value("", -67), yEnd: .value("", -35)).foregroundStyle(Grade.good.color.opacity(0.08))
        RectangleMark(yStart: .value("", -75), yEnd: .value("", -67)).foregroundStyle(Grade.fair.color.opacity(0.09))
        RectangleMark(yStart: .value("", -95), yEnd: .value("", -75)).foregroundStyle(Grade.bad.color.opacity(0.07))
        ForEach(e.samples.filter { $0.rssi != nil }) { s in
          LineMark(x: .value("시각", s.t), y: .value("신호", s.rssi!)).foregroundStyle(K.accent).interpolationMethod(.monotone)
        }
      }
      .chartYScale(domain: -95 ... -35).chartXAxis(.hidden).chartYAxis(.hidden)
      .frame(height: 40)
    }
  }

  // ── 숫자 대신 말 3칸 ──
  var chips: some View {
    HStack(spacing: 8) {
      chip("신호", e.rssi == nil ? "없음" : e.signalWord, e.signalGrade.color)
      chip("끊김", e.lossWord, e.pingBlocked ? K.sub : e.lossGrade.color)   // pingBlocked: ping만 막힌 와이파이
      let l = e.latency ?? 999
      chip("반응", e.latency == nil ? "재는 중" : l < 50 ? "빠름" : l < 100 ? "보통" : "느림", e.latency == nil ? K.sub : l < 50 ? Grade.good.color : l < 100 ? Grade.fair.color : Grade.bad.color)
    }
  }
  func chip(_ k: String, _ v: String, _ c: Color) -> some View {
    VStack(spacing: 2) {
      Text(k).font(.system(size: 12)).foregroundStyle(K.sub)
      Text(v).font(.system(size: 14, weight: .semibold)).foregroundStyle(c).lineLimit(1)
    }
    .frame(maxWidth: .infinity).frame(height: 46)
    .background(RoundedRectangle(cornerRadius: 6).fill(K.soft))
  }

  // ── 자세히(숫자와 용어는 여기만) ──
  var detail: some View {
    let p = e.samples.compactMap { $0.ping }
    let rows: [(String, String)] = [
      ("와이파이", (e.ssid ?? "이름 숨김") + (e.band.isEmpty ? "" : " · \(e.band)")),
      ("연결 속도", e.txRate.map { "\(Int($0))Mbps" } ?? "–"),
      ("신호(RSSI)", e.rssi.map { "\($0) dBm" } ?? "–"),
      ("신호 대 잡음(SNR)", e.snr.map { "\($0) dB" } ?? "–"),
      ("지연(1.1.1.1, 30초 중간값)", ms(e.latency)),
      ("흔들림(지터)", ms(e.jitter)),
      ("손실(60초)", e.pingBlocked ? "측정 안 됨(이 와이파이는 ping을 막아요)" : String(format: "%.0f%%", e.loss)),
      ("최고 지연(60초)", p.max().map { String(format: "%.0fms", $0) } ?? "–"),
      ("코딩 서버 연결(github.com)", ms(e.codeMs)),
      ("점수", "\(e.score) / 100"),
    ]
    return VStack(alignment: .leading, spacing: 6) {
      Text("자세한 숫자").font(.system(size: 13, weight: .semibold)).foregroundStyle(K.ink)
      ForEach(rows, id: \.0) { r in
        HStack { Text(r.0).foregroundStyle(K.sub); Spacer(minLength: 16); Text(r.1).foregroundStyle(K.ink).monospacedDigit() }.font(.system(size: 12))
      }
      Text("줌 기준: 지터 30ms · 손실(60초) 2% · 지연 100ms 아래\n코딩 기준: 지연 150ms 아래 · 손실 1% 아래")
        .font(.system(size: 10)).foregroundStyle(K.sub).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
    }.padding(14).frame(width: 340)
  }

  func ms(_ v: Double?) -> String { v.map { String(format: "%.0fms", $0) } ?? "–" }
}

struct MenuView: View {
  @EnvironmentObject var e: Engine
  @Environment(\.openWindow) private var openWindow
  @State private var visible = false   // 패널이 열려 있을 때만 링·그래프를 그린다(닫힌 동안 1초마다 다시 그리지 않게)
  // 점수 색 = 메뉴 막대 점과 같은 기준(70↑ 초록, 45↑ 주황, 그 아래 빨강)
  var scoreColor: Color { e.rssi == nil ? K.sub : e.score >= 70 ? Grade.good.color : e.score >= 45 ? Grade.fair.color : Grade.bad.color }
  var signalColor: Color {
    guard e.rssi != nil else { return K.sub }
    switch e.signalWord { case "아주 좋음", "좋음": return Grade.good.color; case "약함": return Grade.fair.color; default: return Grade.bad.color }
  }
  // 메뉴 막대 패널: 너비 232 고정, 작은 링 + 점수·신호, 1분 스파크라인, 줌·코딩 색 점 한 줄
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if visible {
        HStack(alignment: .center, spacing: 12) {
          ZStack {
            Circle().stroke(K.line, lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(e.rssi == nil ? 0 : e.score) / 100).stroke(scoreColor, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
          }.frame(width: 40, height: 40).padding(2)
          VStack(alignment: .leading, spacing: 2) {
            Text(e.rssi == nil ? "–" : "\(e.score)점").font(.system(size: 20, weight: .bold)).foregroundStyle(scoreColor).monospacedDigit()
            (Text("신호 ").foregroundColor(K.ink) + Text(e.signalWord).foregroundColor(signalColor).bold()).font(.system(size: 14)).lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
        Chart {
          RectangleMark(yStart: .value("", -67), yEnd: .value("", -35)).foregroundStyle(Grade.good.color.opacity(0.08))
          RectangleMark(yStart: .value("", -75), yEnd: .value("", -67)).foregroundStyle(Grade.fair.color.opacity(0.09))
          RectangleMark(yStart: .value("", -95), yEnd: .value("", -75)).foregroundStyle(Grade.bad.color.opacity(0.07))
          ForEach(e.samples.filter { $0.rssi != nil }) { s in
            LineMark(x: .value("시각", s.t), y: .value("신호", s.rssi!)).foregroundStyle(K.accent).interpolationMethod(.monotone)
          }
        }
        .chartYScale(domain: -95 ... -35).chartXAxis(.hidden).chartYAxis(.hidden)
        .frame(height: 30).padding(.horizontal, 12)
        .accessibilityLabel("최근 1분 신호")
        HStack(spacing: 16) {
          gradeDot("줌", e.zoomGrade)
          gradeDot("코딩", e.codeGrade)
          Spacer(minLength: 0)
        }
        .font(.system(size: 14)).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
      } else {
        Color.clear.frame(height: 128)
      }
      Rectangle().fill(K.line).frame(height: 1)
      VStack(spacing: 2) {
        PanelRow(title: "창 열기") { NSApp.keyWindow?.orderOut(nil); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        PanelRow(title: "끝내기") { NSApp.terminate(nil) }
      }.padding(6)
    }
    .frame(width: 232, alignment: .leading)
    .background(Color.white)
    .preferredColorScheme(.light)
    .onAppear { visible = true }
    .onDisappear { visible = false }
  }
  func gradeDot(_ k: String, _ g: Grade) -> some View {
    HStack(spacing: 6) {
      Circle().fill(g.color).frame(width: 8, height: 8)
      (Text(k + " ").foregroundColor(K.ink) + Text(g.word).foregroundColor(g.color).bold()).lineLimit(1).fixedSize()
    }
  }
}

/// 패널 아래 줄 버튼: 너비 가득, 높이 30, 글자 상하 가운데, 올리면 차가운 회색 바탕(모서리 6, 알약 아님)
struct PanelRow: View {
  var title: String
  var action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 14)).foregroundStyle(K.ink)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? K.soft2 : Color.clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).onHover { hover = $0 }
  }
}
