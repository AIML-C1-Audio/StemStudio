import SwiftUI
import WebKit

// Renders a real engraved score (treble staff, key signature, chord noteheads,
// single-row lyrics) with VexFlow inside a WKWebView. VexFlow is bundled locally
// (StemStudio/Resources/vexflow.js) and inlined — no network access.
struct ScoreNotationView: NSViewRepresentable {
    let score: ScoreAsset
    let zoom: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        context.coordinator.zoom = zoom
        context.coordinator.loadedScoreID = score.id
        webView.loadHTMLString(Self.html(for: score), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.loadedScoreID != score.id {
            coordinator.loadedScoreID = score.id
            coordinator.zoom = zoom
            webView.loadHTMLString(Self.html(for: score), baseURL: nil)
        } else if coordinator.zoom != zoom {
            coordinator.zoom = zoom
            webView.evaluateJavaScript("render(\(zoom));", completionHandler: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var zoom: Double = 1.0
        var loadedScoreID: UUID?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("render(\(zoom));", completionHandler: nil)
        }
    }

    // MARK: - HTML / payload

    private static func html(for score: ScoreAsset) -> String {
        let vexflow = loadVexflow()
        let payload = notationJSON(for: score)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          html,body { margin:0; padding:0; background:#f7f7f8; }
          #score { padding:14px; }
          #score svg { max-width:none; }
        </style></head>
        <body>
        <div id="score"></div>
        <script>\(vexflow)</script>
        <script>
        const SCORE = \(payload);
        function render(zoom){
          const VF = Vex.Flow;
          const host = document.getElementById('score');
          host.innerHTML = '';
          const MEAS = SCORE.measures || [];
          if(!MEAS.length){ host.textContent = 'No measures.'; return; }

          const perLine = 3, totalW = 1180, leftM = 10, topM = 10;
          const firstExtra = 64;                 // clef + key signature room
          const usable = totalW - leftM*2;
          const mW = (usable - firstExtra) / perLine;
          const lineH = 150;
          const rows = Math.ceil(MEAS.length / perLine);
          const totalH = topM + rows*lineH + 20;

          const renderer = new VF.Renderer(host, VF.Renderer.Backends.SVG);
          renderer.resize(Math.ceil(totalW*zoom), Math.ceil(totalH*zoom));
          const ctx = renderer.getContext();
          ctx.scale(zoom, zoom);
          ctx.setFillStyle('#141414'); ctx.setStrokeStyle('#141414');

          const keySig = SCORE.key || 'C';
          let prevChord = null;                  // for chord-symbol de-duplication
          for(let i=0;i<MEAS.length;i++){
            const row = Math.floor(i/perLine), col = i%perLine;
            const isFirst = (col === 0);
            const x = leftM + (col>0 ? (mW+firstExtra) + (col-1)*mW : 0);
            const w = isFirst ? mW+firstExtra : mW;
            const y = topM + row*lineH;

            const stave = new VF.Stave(x, y, w);
            if(isFirst){ stave.addClef('treble'); if(keySig) stave.addKeySignature(keySig); }
            stave.setContext(ctx).draw();

            const notes = MEAS[i].beats.map(b=>{
              const n = (b.rest || !b.keys.length)
                ? new VF.StaveNote({keys:['b/4'], duration:'qr'})
                : new VF.StaveNote({keys:b.keys, duration:'q'});

              // Chord symbol above the staff — only when the chord changes.
              if(b.chord && b.chord !== 'N' && b.chord !== prevChord){
                const c = new VF.Annotation(b.chord)
                  .setVerticalJustification(VF.Annotation.VerticalJustify.TOP)
                  .setFont('Arial', 13, 'bold');
                n.addModifier(c, 0);
              }
              if(b.chord && b.chord !== 'N') prevChord = b.chord;

              // Lyric below the staff (single row).
              if(b.lyric){
                const a = new VF.Annotation(b.lyric)
                  .setVerticalJustification(VF.Annotation.VerticalJustify.BOTTOM)
                  .setFont('Arial', 10);
                n.addModifier(a, 0);
              }
              return n;
            });

            const voice = new VF.Voice({num_beats: SCORE.beatsPerBar||4, beat_value:4})
              .setMode(VF.Voice.Mode.SOFT)
              .addTickables(notes);
            try { VF.Accidental.applyAccidentals([voice], keySig); } catch(e){}
            const fmtW = w - (isFirst ? firstExtra+24 : 22);
            new VF.Formatter().joinVoices([voice]).format([voice], Math.max(40, fmtW));
            voice.draw(ctx, stave);
          }
        }
        </script>
        </body></html>
        """
    }

    private static func loadVexflow() -> String {
        if let bundled = Bundle.main.url(forResource: "vexflow", withExtension: "js"),
           let text = try? String(contentsOf: bundled, encoding: .utf8) {
            return text
        }
        // Dev fallback: read from the repo Resources folder via this file's path.
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // Score
        url.deleteLastPathComponent()   // Views
        url.deleteLastPathComponent()   // StemStudio (source root)
        url.appendPathComponent("Resources/vexflow.js")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "throw new Error('VexFlow missing');"
    }

    private struct Payload: Encodable {
        struct Beat: Encodable { let keys: [String]; let lyric: String; let rest: Bool; let chord: String }
        struct Measure: Encodable { let beats: [Beat] }
        let key: String
        let beatsPerBar: Int
        let measures: [Measure]
    }

    private static func notationJSON(for score: ScoreAsset) -> String {
        let measures = (score.measures ?? []).map { m in
            Payload.Measure(beats: m.beats.map { b in
                let isRest = b.chord == "N" || b.triad.isEmpty
                return Payload.Beat(
                    keys: isRest ? [] : b.triad.map { vexKey($0.pitch) },
                    lyric: b.lyric,
                    rest: isRest,
                    chord: b.chord
                )
            })
        }
        let payload = Payload(
            key: score.key ?? "C",
            beatsPerBar: score.beatsPerBar ?? 4,
            measures: measures
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"measures\":[]}"
        }
        return json
    }

    // "F#4" -> "f#/4", "A4" -> "a/4", "Bb3" -> "bb/3"
    private static func vexKey(_ pitch: String) -> String {
        guard let letter = pitch.first else { return "c/4" }
        var accidental = ""
        var index = pitch.index(after: pitch.startIndex)
        if index < pitch.endIndex, pitch[index] == "#" || pitch[index] == "b" {
            accidental = String(pitch[index])
            index = pitch.index(after: index)
        }
        let octave = String(pitch[index...])
        return "\(String(letter).lowercased())\(accidental)/\(octave)"
    }
}
