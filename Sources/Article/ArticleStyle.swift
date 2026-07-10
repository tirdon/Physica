// ArticleStyle — the article stylesheet, embedded in the wasm bundle so the
// renderer is self-contained: `ArticleDOM.render` injects this as a `<style>`
// element into `<head>` rather than relying on the shell page to carry the CSS.
//
// Platform-neutral (just a string constant), kept as an extended raw string
// literal (`#"""…"""#`) so the CSS's own `"`-quoted font names and backslash
// escapes (`\21B5`, `\25B7`, `\00a0`) survive verbatim — no Swift escaping.
//
// Adapted wholesale from the reference Medium-style article page. A consumer can
// read `ArticleStyle.css` to reuse or override it.
//
// Every color the page uses is a `:root` variable (the `:root` block below IS
// the light palette), so `theme(background:)` can restyle the whole article by
// emitting one variable-override block — see `Document(background:)`.

import PhysicaFoundation

public enum ArticleStyle {
    /// The DOM id of the injected `<style>` element (used to dedupe re-renders).
    public static let elementID = "physica-article-style"

    public static let css = #"""
  :root{
    --paper:#FAF7F2; --paper-2:#F0EBE1; --text:#2A2825; --text-2:#6E6A62; --text-3:#948F84;
    --rule:#EAE4D8; --rule-2:#DDD6C7; --rule-soft:#ECE8E0; --accent:#1A8917; --accent-soft:#E8F1E4;
    --card:#FFFFFF; --veil:rgba(250,247,242,.92); --underline:#C7C7C7;
    --serif:"Charter","Source Serif 4",Georgia,"Times New Roman",serif;
    --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    --mono:"SF Mono","Menlo","Monaco","Cascadia Code",ui-monospace,monospace;
  }
  *{box-sizing:border-box}
  html{scroll-behavior:smooth}
  html,body{margin:0}
  body{
    background:var(--paper); color:var(--text);
    font-family:var(--serif); font-size:21px; line-height:1.58; letter-spacing:-.003em;
    -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility;
  }

  /* ---------- top bar ---------- */
  .topbar{
    position:sticky; top:0; z-index:20; background:var(--veil);
    backdrop-filter:saturate(140%) blur(8px);
    border-bottom:1px solid var(--rule);
  }
  .topbar .row{max-width:1080px; margin:0 auto; padding:13px 26px;
    display:flex; align-items:center; gap:14px; font-size:13px}
  .topbar .brand{font-weight:700; letter-spacing:-.01em}
  .topbar .brand b{color:var(--accent)}
  .topbar .sub{color:var(--text-3); font-family:var(--mono); font-size:12px}
  .topbar nav{margin-left:auto; display:flex; gap:16px}
  .topbar nav a{color:var(--text-2); text-decoration:none; font-size:13px; font-family:var(--mono)}
  .topbar nav a:hover{color:var(--accent)}

  /* ---------- article column ---------- */
  .paper{max-width:680px; margin:0 auto; padding:50px 24px 96px}
  .eyebrow{
    font-family:var(--sans); font-size:13px; letter-spacing:.01em; font-weight:600;
    color:var(--accent); display:flex; align-items:center; gap:8px; margin:0 0 16px;
  }
  .eyebrow::before{content:""; width:7px; height:7px; border-radius:50%; background:var(--accent)}
  h1{
    font-family:var(--serif); font-weight:700;
    font-size:clamp(34px,5.2vw,46px); line-height:1.18; letter-spacing:-.019em;
    margin:0 0 16px; color:var(--text);
  }
  .subtitle{font-family:var(--serif); font-weight:400; font-size:22px; line-height:1.4;
    color:var(--text-2); margin:0 0 24px}
  .byline{display:flex; align-items:center; gap:13px; font-family:var(--sans); font-size:14px;
    color:var(--text-2); margin:22px 0 36px; padding-bottom:28px; border-bottom:1px solid var(--rule)}
  .byline .avatar{width:44px; height:44px; border-radius:50%; flex:none; letter-spacing:.02em;
    background:linear-gradient(135deg,#1FA01B,#0E5A10); color:#fff; font-weight:700; font-family:var(--sans);
    display:flex; align-items:center; justify-content:center; font-size:15px}
  .byline .who{display:flex; flex-direction:column; line-height:1.4}
  .byline .who .nm{color:var(--text); font-weight:600}
  .byline .who .meta2 b{color:var(--text); font-weight:600}
  .abstract{font-size:21px; line-height:1.58; color:var(--text); margin:0 0 24px}

  p{margin:0 0 24px}
  a{color:var(--text); text-decoration:underline; text-decoration-color:var(--underline); text-underline-offset:2px}
  a:hover{color:var(--accent); text-decoration-color:var(--accent)}
  em{font-style:italic}
  strong{font-weight:700}
  code{font-family:var(--mono); font-size:.8em; background:var(--paper-2);
    border-radius:4px; padding:.08em .4em; color:var(--text)}

  h2{
    font-family:var(--serif); font-weight:700; font-size:clamp(26px,3.4vw,30px); letter-spacing:-.015em;
    line-height:1.25; margin:52px 0 6px; color:var(--text); scroll-margin-top:66px;
    display:flex; align-items:baseline; gap:12px;
  }
  h2 .sec{
    font-family:var(--sans); font-size:15px; font-weight:600; color:var(--text-3);
    letter-spacing:0; flex:none;
  }
  h2 + p, h2 + .notation, h2 + .procedure, h2 + .mathblock{margin-top:14px}
  h3{font-family:var(--sans); font-weight:700; font-size:17px; margin:32px 0 4px; color:var(--text)}
  h4{font-family:var(--sans); font-weight:700; font-size:14.5px; letter-spacing:.01em;
    text-transform:uppercase; color:var(--text-2); margin:26px 0 4px}

  /* ---------- stat chips ---------- */
  .stats{display:flex; flex-wrap:wrap; gap:9px; margin:0 0 6px}
  .stat{
    border:1px solid var(--rule-2); background:var(--card); border-radius:9px;
    padding:8px 14px; display:flex; align-items:baseline; gap:8px;
  }
  .stat b{font-family:var(--serif); font-weight:600; font-size:19px; color:var(--accent); letter-spacing:-.01em}
  .stat span{font-family:var(--mono); font-size:10px; letter-spacing:.14em; text-transform:uppercase; color:var(--text-3)}

  /* ---------- notation / definition table ---------- */
  .notation{
    margin:8px 0 6px; border-top:1px solid var(--rule-2); border-bottom:1px solid var(--rule-2);
    display:grid; grid-template-columns:max-content 1fr;
  }
  .notation > div{display:contents}
  .notation dt{
    font-family:var(--mono); font-size:14px; color:var(--text); padding:9px 22px 9px 2px;
    border-top:1px solid var(--rule); white-space:nowrap;
  }
  .notation dd{
    margin:0; padding:9px 0; color:var(--text-2); font-size:15px; border-top:1px solid var(--rule);
  }
  .notation dt:first-of-type, .notation dd:first-of-type{border-top:none}

  /* ---------- display math spacing ---------- */
  .mathblock{overflow-x:auto; overflow-y:hidden}
  mjx-container[display="true"]{margin:22px 0 !important; overflow-x:auto; overflow-y:hidden}

  /* ---------- procedure / algorithm float ---------- */
  .procedure{
    margin:26px 0; padding:0 2px 12px; border-top:2.5px solid var(--text); border-bottom:2.5px solid var(--text);
    font-size:15px;
  }
  .procedure .cap{
    display:flex; align-items:baseline; gap:12px; flex-wrap:wrap;
    padding:11px 0 10px; border-bottom:1px solid var(--rule-2); margin-bottom:11px;
  }
  .procedure .cap .k{font-weight:700; font-family:var(--sans)}
  .procedure .cap .k em{color:var(--accent); font-style:normal}
  .procedure .cap .ttl{color:var(--text-2); font-size:14px}
  .procedure .io{font-size:14px; color:var(--text-2); margin:3px 0; padding-left:2px}
  .procedure .io b{color:var(--text); font-weight:650; font-family:var(--mono); font-size:12.5px;
    letter-spacing:.04em; text-transform:uppercase; margin-right:8px}
  .procedure ol{list-style:none; counter-reset:ln; margin:10px 0 2px; padding:0}
  .procedure ol li{
    counter-increment:ln; position:relative; padding:4px 0 4px 40px; line-height:1.5;
    border-top:1px dotted var(--rule-soft);
  }
  .procedure ol li:first-child{border-top:none}
  .procedure ol li::before{
    content:counter(ln) ":"; position:absolute; left:0; top:4px; width:30px; text-align:right;
    font-family:var(--mono); font-size:12.5px; color:var(--text-3);
  }
  .procedure ol li.ret{font-weight:600}
  .procedure ol li.ret::before{content:"\21B5"; color:var(--accent)}
  .procedure ol li .cm{color:var(--text-3); font-size:13.5px}
  .procedure ol li .cm::before{content:"\25B7\00a0"; color:var(--rule-2)}
  .procedure .foot{font-size:13px; color:var(--text-3); margin:10px 2px 0; line-height:1.55}

  /* ---------- generic table (grid mixing math + text cells) ---------- */
  .dtable{
    display:grid; gap:0 22px; margin:18px 0 8px;
    border-top:1px solid var(--rule-2); align-items:baseline;
  }
  .dtable .dcell{
    padding:12px 2px; font-size:15px; color:var(--text-2); line-height:1.5;
    border-bottom:1px solid var(--rule);
  }
  .dtable .dcell-math{font-family:var(--serif); color:var(--text); font-size:17px; white-space:nowrap}
  .dtable.sep-col .dcell:nth-child(odd){border-right:1px solid var(--rule); padding-right:22px}

  /* ---------- figure ---------- */
  .figure{margin:28px 0}
  .figure img{display:block; width:100%; height:auto; border-radius:12px; border:1px solid var(--rule)}
  .figure figcaption{
    font-family:var(--sans); font-size:14px; color:var(--text-3); line-height:1.55;
    text-align:center; margin-top:10px;
  }

  /* ---------- presentation deck (embedded Physica Story) ---------- */
  .story-deck{
    margin:28px 0; border:1px solid #202834; border-radius:16px; overflow:hidden;
    background:linear-gradient(180deg,#10141C,#0C0F15);
    box-shadow:0 30px 70px -48px #000;
  }
  .story-stage{
    position:relative; height:clamp(300px,42vh,420px); outline:none;
    background:linear-gradient(180deg,#11161F,#0D1119);
  }
  .story-canvas{display:block; width:100%; height:100%; touch-action:pan-y;
    -webkit-user-select:none; user-select:none}
  .story-deck-caption{
    position:absolute; left:50%; bottom:18px; transform:translateX(-50%);
    max-width:min(88%,600px); padding:9px 16px; border-radius:10px;
    background:rgba(10,16,12,.74); color:#eef4ee;
    font-family:var(--sans); font-size:15px; line-height:1.5; text-align:center;
    opacity:0; transition:opacity .25s ease; pointer-events:none;
  }
  .story-deck-caption.show{opacity:1}
  .story-deck-caption strong{color:#fff; font-weight:700}
  .story-deck-caption code{background:rgba(255,255,255,.09); color:#dfeee6; font-size:.82em}
  .story-deck .deck-nav{
    display:flex; align-items:center; gap:12px; padding:12px 18px;
    border-top:1px solid #202834; background:#0E1117;
  }
  .story-deck .deck-btn{
    font-family:var(--sans); font-size:13px; font-weight:600; color:#9AA4B8;
    background:#151B26; border:1px solid #28303F; border-radius:8px; padding:7px 13px; cursor:pointer;
    transition:.15s color,.15s border-color;
  }
  .story-deck .deck-btn:hover{color:#E9EDF4; border-color:#3A4458}
  .story-deck .deck-dots{display:flex; gap:8px; margin:0 auto}
  .story-deck .deck-dot{
    width:9px; height:9px; padding:0; border-radius:50%; border:none;
    background:#28303F; cursor:pointer; transition:.15s background;
  }
  .story-deck .deck-dot.active{background:var(--accent)}
  .story-deck .deck-count{font-family:var(--mono); font-size:12px; color:#69728A}

  /* ---------- footer ---------- */
  footer.foot{margin-top:60px; padding-top:24px; border-top:1px solid var(--rule);
    font-family:var(--sans); font-size:14px; color:var(--text-3); line-height:1.7}
  footer.foot b{color:var(--text-2); font-weight:500}

  @media (max-width:920px){
    .dtable{grid-template-columns:1fr !important; gap:0}
    .dtable.sep-col .dcell:nth-child(odd){border-right:none; padding-right:2px}
  }
  @media (prefers-reduced-motion:reduce){
    html{scroll-behavior:auto}
  }
"""#

    // MARK: - Background themes (`Document(background:)`)

    /// The DOM id of the theme-override `<style>` — a second element injected
    /// after the base sheet (so its `:root` wins) and updated in place when a
    /// re-render switches themes.
    public static let themeElementID = "physica-article-theme"

    /// A `:root` variable-override block for a page background. The palette is
    /// picked by the background's luminance — `.documentDark` (or any dark
    /// color) gets light ink and a brighter accent; a light color keeps the
    /// stock warm-gray ink. `--paper` is the exact color given; its supporting
    /// shades (code chips, stat cards, rules, the topbar veil) are derived from
    /// it, so off-palette customs stay coherent. The default `.documentLight`
    /// page never injects this (see `ArticleDOM.applyTheme`) — the hand-tuned
    /// `:root` constants above stay authoritative there.
    public static func theme(background: Color) -> String {
        let paper = css(background)
        let veil = veil(background)
        if isDark(background) {
            return """
            :root{
              --paper:\(paper); --paper-2:\(css(background.lighter(0.06)));
              --text:#E9E7E1; --text-2:#A9A49B; --text-3:#7E7970;
              --rule:\(css(background.lighter(0.09))); --rule-2:\(css(background.lighter(0.16)));
              --rule-soft:\(css(background.lighter(0.12)));
              --accent:#33B133; --accent-soft:#1B2B1C;
              --card:\(css(background.lighter(0.045))); --veil:\(veil);
              --underline:#514F58;
            }
            """
        }
        return """
        :root{
          --paper:\(paper); --paper-2:\(css(background.darker(0.045)));
          --text:#2A2825; --text-2:#6E6A62; --text-3:#948F84;
          --rule:\(css(background.darker(0.08))); --rule-2:\(css(background.darker(0.14)));
          --rule-soft:\(css(background.darker(0.06)));
          --accent:#1A8917; --accent-soft:#E8F1E4;
          --card:#FFFFFF; --veil:\(veil);
          --underline:#C7C7C7;
        }
        """
    }

    /// Perceived-luminance split (Rec. 709 weights on the stored sRGB values —
    /// coarse, but themes only need the light/dark call).
    private static func isDark(_ color: Color) -> Bool {
        0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b < 0.5
    }

    private static func css(_ color: Color) -> String {
        "rgb(\(channel(color.r)),\(channel(color.g)),\(channel(color.b)))"
    }

    /// The topbar's translucent backdrop: the paper color at the sheet's .92.
    private static func veil(_ color: Color) -> String {
        "rgba(\(channel(color.r)),\(channel(color.g)),\(channel(color.b)),.92)"
    }

    private static func channel(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}
