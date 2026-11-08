package amqp

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

func validPathSegment(value string) bool {
	if value == "" || utf8.RuneCountInString(value) > 128 || strings.ContainsAny(value, "<>:\"/\\|?*") || strings.HasSuffix(value, ".") || strings.HasSuffix(value, " ") {
		return false
	}
	for _, r := range value {
		if r < 32 {
			return false
		}
	}
	base := strings.ToLower(strings.SplitN(value, ".", 2)[0])
	if base == "con" || base == "prn" || base == "aux" || base == "nul" {
		return false
	}
	if len(base) == 4 && (strings.HasPrefix(base, "com") || strings.HasPrefix(base, "lpt")) && base[3] >= '1' && base[3] <= '9' {
		return false
	}
	return true
}

var vmGUID = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
