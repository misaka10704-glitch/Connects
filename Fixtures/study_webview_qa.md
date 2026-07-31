# Study WebView QA Fixture

Long Markdown used to stress Study reading WKWebView (KaTeX + fences + tables).

## Section A · Math

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

Inline: \(\delta(t)\), \(\mathcal{L}\{f\}(s)\), \(\mathbb{R}\).

$$
y[n] = (x * h)[n] = \sum_{k=-\infty}^{\infty} x[k]\,h[n-k]
$$

## Section B · Code fences

```verilog
module stress_web_qa(
  input  wire [31:0] in,
  output wire [31:0] out
);
  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin : g
      assign out[i] = in[i] ^ in[(i+1)%32];
    end
  endgenerate
endmodule
```

```swift
enum WebQA {
  static func line(_ n: Int) -> String { "row_\(n)_aaaaaaaa_bbbbbbbb" }
}
```

## Section C · Table

| idx | name | note |
|----:|------|------|
| 1 | alpha | first |
| 2 | beta | second |
| 3 | gamma | third |
| 4 | delta | fourth |
| 5 | epsilon | fifth |

## Section D · Repeated body

PLACEHOLDER

## Section E · More math

$$
\sup S = \inf\{ u \mid \forall x\in S,\, x\le u \}
$$

> Scroll must stay on WKWebView.scrollView only — no sticky nested body overflow.
