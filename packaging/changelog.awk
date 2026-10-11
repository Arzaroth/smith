# CHANGELOG.md's releases as package changelogs, one entry per bullet:
#   awk -v format=deb -v name=NAME -v packager='Name <email>' -f changelog.awk CHANGELOG.md
#   awk -v format=chglog -v packager='Name <email>' -f changelog.awk CHANGELOG.md
# deb is debian/changelog's format; chglog is the YAML nfpm turns into the
# rpm's %changelog.

function wrap(text, first, rest,    words, n, i, line, out) {
  n = split(text, words, " ")
  line = first words[1]
  for (i = 2; i <= n; i++) {
    if (length(line) + 1 + length(words[i]) > 79) {
      out = out line "\n"
      line = rest words[i]
    } else {
      line = line " " words[i]
    }
  }
  return out line
}

function weekday(y, m, d,    t) {
  split("0 3 2 5 0 3 5 1 4 6 2 4", t, " ")
  if (m < 3) y--
  return substr("SunMonTueWedThuFriSat", 1 + 3 * ((y + int(y / 4) - int(y / 100) + int(y / 400) + t[m] + d) % 7), 3)
}

function flush() {
  if (note == "") return
  gsub(/`/, "", note)
  if (format == "deb") {
    print wrap(note, "  * ", "    ")
  } else {
    note = substr(wrap(note, "- ", "  "), 3)
    gsub(/\n/, "\n        ", note)
    print "    - note: |-\n        " note
  }
  note = ""
  notes++
}

function fail(why) {
  printf "%s:%d: %s\n", FILENAME, NR, why > "/dev/stderr"
  failed = 1
  exit 1
}

function close_release() {
  flush()
  if (release && !notes) fail("release " version " has no bullets")
  if (format == "deb" && trailer != "") print "\n" trailer
  trailer = ""
}

/^## / {
  close_release()
  release = $2 != "[Unreleased]"
  if (!release) next
  version = $2
  gsub(/\[|\]/, "", version)
  if ($3 != "-" || $4 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) fail("expected ## [x.y.z] - YYYY-MM-DD")
  notes = 0
  split($4, ymd, "-")
  if (format == "deb") {
    if (entries++) print ""
    print name " (" version ") stable; urgency=low\n"
    trailer = sprintf(" -- %s  %s, %s %s %s 00:00:00 +0000", packager, weekday(ymd[1] + 0, ymd[2] + 0, ymd[3] + 0), ymd[3], substr("JanFebMarAprMayJunJulAugSepOctNovDec", 3 * ymd[2] - 2, 3), ymd[1])
  } else {
    print "- semver: " version "-1"
    print "  date: " $4 "T00:00:00Z"
    print "  packager: " packager
    print "  changes:"
  }
  next
}

!release { next }

/^- / {
  flush()
  note = substr($0, 3)
  next
}

/^ +[^ ]/ && note != "" {
  sub(/^ +/, "")
  note = note " " $0
  next
}

/^(### .*)?$/ {
  flush()
  next
}

{ fail("not a bullet, a continuation line or a ### heading") }

END {
  if (!failed) close_release()
}
