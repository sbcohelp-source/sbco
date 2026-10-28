#let d = json(bytes(sys.inputs.data))
#set text(font: ("Noto Sans", "Noto Sans Devanagari", "Noto Sans Bengali", "Noto Sans Gujarati", "Noto Sans Gurmukhi", "Noto Sans Kannada", "Noto Sans Malayalam", "Noto Sans Oriya", "Noto Sans Tamil", "Noto Sans Telugu", "Noto Sans Arabic"), size: 9pt, fill: rgb("20352e"))
#set page(paper: "a4", flipped: d.landscape, margin: (x: 14mm, top: 17mm, bottom: 18mm), header: text(size: 8pt, fill: rgb("64756d"))[#if d.title.starts-with("TRAINING") { [TRAINING / NOT FOR OFFICIAL USE] } else { [SBCO / Voucher Verification] }], footer: context align(right, text(size: 8pt)[Page #counter(page).display("1 / 1", both: true)]))
#set par(leading: 0.6em)
#set heading(numbering: none)
// Long account/reference tokens have no natural line-break points. Add invisible
// break opportunities to ASCII runs only, preserving complex-script shaping.
#show regex("[A-Za-z0-9_./:@-]{24,}"): it => text(it.text.clusters().join("\u{200b}"))
#show heading.where(level: 1): set text(size: 18pt, fill: rgb("0d3329"))
#show heading.where(level: 2): set text(size: 11pt, fill: rgb("0d3329"))
#heading(level: 1, d.title)
#text(size: 9pt, d.subtitle)
#v(3mm)
#for s in d.sections {
  if s.title != "" { heading(level: 2, s.title) }
  table(
    columns: s.widths.map(w => w * 1fr),
    stroke: 0.4pt + rgb("cad5ce"),
    inset: 5pt,
    fill: (x, y) => if y == 0 { rgb("e7f0ea") } else if calc.odd(y) { rgb("f8faf8") },
    table.header(..s.columns.map(c => strong(c))),
    ..s.rows.flatten().map(c => text(c)),
  )
  v(3mm)
}
#for note in d.notes { par(text(size: 8pt, note)) }
#if d.signatory != "" or d.designation != "" {
  v(8mm)
  align(right, block[
    #strong(d.signatory) \
    #d.designation
  ])
}
