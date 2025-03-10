// urllib parses URLs and implements query escaping.

// See RFC 3986. This module generally follows RFC 3986, except where
// it deviates for compatibility reasons.

// Based off:   https://github.com/golang/go/blob/master/src/net/url/url.go
// Last commit: https://github.com/golang/go/commit/61bb56ad63992a3199acc55b2537c8355ef887b6
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

module urllib

import strings

enum EncodingMode {
	encode_path
	encode_path_segment
	encode_host
	encode_zone
	encode_user_password
	encode_query_component
	encode_fragment
}

const (
	err_msg_escape = 'invalid URL escape'
	err_msg_parse  = 'error parsing url'
)

fn error_msg(message, val string) string {
	mut msg := 'net.urllib: $message'
	if val != '' { msg = '$msg ($val)' }
	return msg
}

// Return true if the specified character should be escaped when
// appearing in a URL string, according to RFC 3986.
//
// Please be informed that for now should_escape does not check all
// reserved characters correctly. See golang.org/issue/5684.
fn should_escape(c byte, mode EncodingMode) bool {
	// §2.3 Unreserved characters (alphanum)
	if (`a` <= c && c <= `z`) || (`A` <= c && c <= `Z`) || (`0` <= c && c <= `9`) {
		return false
	}

	if mode == .encode_host || mode == .encode_zone {
		// §3.2.2 host allows
		//	sub-delims = `!` / `$` / `&` / ``` / `(` / `)` / `*` / `+` / `,` / `;` / `=`
		// as part of reg-name.
		// We add : because we include :port as part of host.
		// We add [ ] because we include [ipv6]:port as part of host.
		// We add < > because they`re the only characters left that
		// we could possibly allow, and parse will reject them if we
		// escape them (because hosts can`t use %-encoding for
		// ASCII bytes).
		switch c {
		case `!`, `$`, `&`, `\\`, `(`, `)`, `*`, `+`, `,`, `;`, `=`, `:`, `[`, `]`, `<`, `>`, `"`:
			return false
		}
	}

	switch c {
	case `-`, `_`, `.`, `~`: // §2.3 Unreserved characters (mark)
		return false

	case `$`, `&`, `+`, `,`, `/`, `:`, `;`, `=`, `?`, `@`: // §2.2 Reserved characters (reserved)
		// Different sections of the URL allow a few of
		// the reserved characters to appear unescaped.
		switch mode {
		case EncodingMode.encode_path: // §3.3
			// The RFC allows : @ & = + $ but saves / ; , for assigning
			// meaning to individual path segments. This package
			// only manipulates the path as a whole, so we allow those
			// last three as well. That leaves only ? to escape.
			return c == `?`

		case EncodingMode.encode_path_segment: // §3.3
			// The RFC allows : @ & = + $ but saves / ; , for assigning
			// meaning to individual path segments.
			return c == `/` || c == `;` || c == `,` || c == `?`

		case EncodingMode.encode_user_password: // §3.2.1
			// The RFC allows `;`, `:`, `&`, `=`, `+`, `$`, and `,` in
			// userinfo, so we must escape only `@`, `/`, and `?`.
			// The parsing of userinfo treats `:` as special so we must escape
			// that too.
			return c == `@` || c == `/` || c == `?` || c == `:`

		case EncodingMode.encode_query_component: // §3.4
			// The RFC reserves (so we must escape) everything.
			return true

		case EncodingMode.encode_fragment: // §4.1
			// The RFC text is silent but the grammar allows
			// everything, so escape nothing.
			return false
		}
	}

	if mode == .encode_fragment {
		// RFC 3986 §2.2 allows not escaping sub-delims. A subset of sub-delims are
		// included in reserved from RFC 2396 §2.2. The remaining sub-delims do not
		// need to be escaped. To minimize potential breakage, we apply two restrictions:
		// (1) we always escape sub-delims outside of the fragment, and (2) we always
		// escape single quote to avoid breaking callers that had previously assumed that
		// single quotes would be escaped. See issue #19917.
		switch c {
		case `!`, `(`, `)`, `*`:
			return false
		}
	}

	// Everything else must be escaped.
	return true
}

// query_unescape does the inverse transformation of query_escape,
// converting each 3-byte encoded substring of the form '%AB' into the
// hex-decoded byte 0xAB.
// It returns an error if any % is not followed by two hexadecimal
// digits.
pub fn query_unescape(s string) ?string {
	return unescape(s, .encode_query_component)
}

// path_unescape does the inverse transformation of path_escape,
// converting each 3-byte encoded substring of the form '%AB' into the
// hex-decoded byte 0xAB. It returns an error if any % is not followed
// by two hexadecimal digits.
//
// path_unescape is identical to query_unescape except that it does not
// unescape '+' to ' ' (space).
pub fn path_unescape(s string) ?string {
	return unescape(s, .encode_path_segment)
}

// unescape unescapes a string; the mode specifies
// which section of the URL string is being unescaped.
fn unescape(s_ string, mode EncodingMode) ?string {
	mut s := s_
	// Count %, check that they're well-formed.
	mut n := 0
	mut has_plus := false
	for i := 0; i < s.len; {
		x := s[i]
		switch x {
		case `%`:
			if s == '' {
				break
			}
			n++
			if i+2 >= s.len || !ishex(s[i+1]) || !ishex(s[i+2]) {
				s = s.right(i)
				if s.len > 3 {
					s = s.left(3)
				}
				return error(error_msg(err_msg_escape, s))
			}
			// Per https://tools.ietf.org/html/rfc3986#page-21
			// in the host component %-encoding can only be used
			// for non-ASCII bytes.
			// But https://tools.ietf.org/html/rfc6874#section-2
			// introduces %25 being allowed to escape a percent sign
			// in IPv6 scoped-address literals. Yay.
			if mode == .encode_host && unhex(s[i+1]) < 8 && s.substr(i, i+3) != '%25' {
				return error(error_msg(err_msg_escape, s.substr(i, i+3)))
			}
			if mode == .encode_zone {
				// RFC 6874 says basically 'anything goes' for zone identifiers
				// and that even non-ASCII can be redundantly escaped,
				// but it seems prudent to restrict %-escaped bytes here to those
				// that are valid host name bytes in their unescaped form.
				// That is, you can use escaping in the zone identifier but not
				// to introduce bytes you couldn't just write directly.
				// But Windows puts spaces here! Yay.
				v := byte(unhex(s[i+1])<<byte(4) | unhex(s[i+2]))
				if s.substr(i, i+3) != '%25' && v != ` ` && should_escape(v, .encode_host) {
					error(error_msg(err_msg_escape, s.substr(i, i+3)))
				}
			}
			i += 3
		case `+`:
			has_plus = mode == .encode_query_component
			i++
		default:
			if (mode == .encode_host || mode == .encode_zone) && s[i] < 0x80 && should_escape(s[i], mode) {
				error(error_msg('invalid character in host name', s.substr(i, i+1)))
			}
			i++
		}
	}

	if n == 0 && !has_plus {
		return s
	}

	mut t := strings.new_builder(s.len - 2*n)
	for i := 0; i < s.len; i++ {
		x := s[i]
		switch x {
		case `%`:
			t.write( byte(unhex(s[i+1])<<byte(4) | unhex(s[i+2])).str() )
			i += 2
		case `+`:
			if mode == .encode_query_component {
				t.write(' ')
			} else {
				t.write('+')
			}
		default:
			t.write(s[i].str())
		}
	}
	return t.str()
}

// query_escape escapes the string so it can be safely placed
// inside a URL query.
pub fn query_escape(s string) string {
	return escape(s, .encode_query_component)
}

// path_escape escapes the string so it can be safely placed inside a URL path segment,
// replacing special characters (including /) with %XX sequences as needed.
pub fn path_escape(s string) string {
	return escape(s, .encode_path_segment)
}

fn escape(s string, mode EncodingMode) string {
	mut space_count := 0
	mut hex_count := 0
	mut c := byte(0)
	for i := 0; i < s.len; i++ {
		c = s[i]
		if should_escape(c, mode) {
			if c == ` ` && mode == .encode_query_component {
				space_count++
			} else {
				hex_count++
			}
		}
	}

	if space_count == 0 && hex_count == 0 {
		return s
	}

	mut buf := [byte(0)].repeat(64)
	mut t := []byte

	required := s.len + 2*hex_count
	if required <= buf.len {
		t = buf.left(required)
	} else {
		t = [byte(0)].repeat(required)
	}

	if hex_count == 0 {
		copy(t, s.bytes())
		for i := 0; i < s.len; i++ {
			if s[i] == ` ` {
				t[i] = `+`
			}
		}
		return string(t)
	}

	ctab := '0123456789ABCDEF'
	mut j := 0
	for i := 0; i < s.len; i++ {
		c1 := s[i]
		if c1 == ` ` && mode == .encode_query_component {
			t[j] = `+`
			j++
		} else if should_escape(c1, mode) {
			t[j] = `%`
			t[j+1] = ctab[c1>>4]
			t[j+2] = ctab[c1&15]
			j += 3
		} else {
			t[j] = s[i]
			j++
		}
	}
	return string(t)
}

// A URL represents a parsed URL (technically, a URI reference).
//
// The general form represented is:
//
//	[scheme:][//[userinfo@]host][/]path[?query][#fragment]
//
// URLs that do not start with a slash after the scheme are interpreted as:
//
//	scheme:opaque[?query][#fragment]
//
// Note that the path field is stored in decoded form: /%47%6f%2f becomes /Go/.
// A consequence is that it is impossible to tell which slashes in the path were
// slashes in the raw URL and which were %2f. This distinction is rarely important,
// but when it is, the code should use raw_path, an optional field which only gets
// set if the default encoding is different from path.
//
// URL's String method uses the escaped_path method to obtain the path. See the
// escaped_path method for more details.
struct URL {
pub: mut:
	scheme      string
	opaque      string    // encoded opaque data
	user        &Userinfo // username and password information
	host        string    // host or host:port
	path        string    // path (relative paths may omit leading slash)
	raw_path    string    // encoded path hint (see escaped_path method)
	force_query bool      // append a query ('?') even if raw_query is empty
	raw_query   string    // encoded query values, without '?'
	fragment    string    // fragment for references, without '#'
}

// user returns a Userinfo containing the provided username
// and no password set.
pub fn user(username string) &Userinfo {
	return &Userinfo{
		username: username,
		password: '',
		password_set: false
	}
}

// user_password returns a Userinfo containing the provided username
// and password.
//
// This functionality should only be used with legacy web sites.
// RFC 2396 warns that interpreting Userinfo this way
// ``is NOT RECOMMENDED, because the passing of authentication
// information in clear text (such as URI) has proven to be a
// security risk in almost every case where it has been used.''
fn user_password(username, password string) &Userinfo {
	return &Userinfo{username, password, true}
}

// The Userinfo type is an immutable encapsulation of username and
// password details for a URL. An existing Userinfo value is guaranteed
// to have a username set (potentially empty, as allowed by RFC 2396),
// and optionally a password.
struct Userinfo {
pub:
	username     string
	password     string
	password_set bool
}

fn (u &Userinfo) empty() bool {
	return u.username == '' && u.password == ''
}

// string returns the encoded userinfo information in the standard form
// of 'username[:password]'.
fn (u &Userinfo) string() string {
	if u.empty() {
		return ''
	}
	mut s := escape(u.username, .encode_user_password)
	if u.password_set {
		s += ':' + escape(u.password, .encode_user_password)
	}
	return s
}

// Maybe rawurl is of the form scheme:path.
// (scheme must be [a-zA-Z][a-zA-Z0-9+-.]*)
// If so, return [scheme, path]; else return ['', rawurl]
fn split_by_scheme(rawurl string) ?[]string {
	for i := 0; i < rawurl.len; i++ {
		c := rawurl[i]		
		if (`a` <= c && c <= `z`) || (`A` <= c && c <= `Z`) {
			// do nothing
		}
		else if (`0` <= c && c <= `9`) || (c == `+` || c == `-` || c == `.`) {
			if i == 0 {
				return ['', rawurl]
			}
		}
		else if c == `:` {
			if i == 0 {
				return error(error_msg('missing protocol scheme', ''))
			}
			return [rawurl.left(i), rawurl.right(i+1)]
		}
		else {
			// we have encountered an invalid character,
			// so there is no valid scheme
			return ['', rawurl]
		}
	}
	return ['', rawurl]
}

fn get_scheme(rawurl string) ?string {
	split := split_by_scheme(rawurl) or {
		return err
	}
	return split[0]
}

// Maybe s is of the form t c u.
// If so, return t, c u (or t, u if cutc == true).
// If not, return s, ''.
fn split(s string, c string, cutc bool) []string {
	i := s.index(c)
	if i < 0 {
		return [s, '']
	}
	if cutc {
		return [s.left(i), s.right(i+c.len)]
	}
	return [s.left(i), s.right(i)]
}

// parse parses rawurl into a URL structure.
//
// The rawurl may be relative (a path, without a host) or absolute
// (starting with a scheme). Trying to parse a hostname and path
// without a scheme is invalid but may not necessarily return an
// error, due to parsing ambiguities.
pub fn parse(rawurl string) ?URL {
	// Cut off #frag
	p := split(rawurl, '#', true)
	u := p[0]
	frag := p[1]
	mut url := _parse(u, false) or {
		return error(error_msg(err_msg_parse, u))
	}
	if frag == '' {
		return url
	}
	f := unescape(frag, .encode_fragment) or {
		return error(error_msg(err_msg_parse, u))
	}
	url.fragment = f
	return url
}

// parse_request_uri parses rawurl into a URL structure. It assumes that
// rawurl was received in an HTTP request, so the rawurl is interpreted
// only as an absolute URI or an absolute path.
// The string rawurl is assumed not to have a #fragment suffix.
// (Web browsers strip #fragment before sending the URL to a web server.)
fn parse_request_uri(rawurl string) ?URL {
	return _parse(rawurl, true)
}

// _parse parses a URL from a string in one of two contexts. If
// via_request is true, the URL is assumed to have arrived via an HTTP request,
// in which case only absolute URLs or path-absolute relative URLs are allowed.
// If via_request is false, all forms of relative URLs are allowed.
fn _parse(rawurl string, via_request bool) ?URL {
	if string_contains_ctl_byte(rawurl) {
		return error(error_msg('invalid control character in URL', rawurl))
	}

	if rawurl == '' && via_request {
		return error(error_msg('empty URL', ''))
	}
	mut url := URL{}

	if rawurl == '*' {
		url.path = '*'
		return url
	}

	// Split off possible leading 'http:', 'mailto:', etc.
	// Cannot contain escaped characters.
	p := split_by_scheme(rawurl) or {
		return error(err)
	}
	url.scheme = p[0]
	mut rest := p[1]
	url.scheme = url.scheme.to_lower()

	// if rest.ends_with('?') && strings.count(rest, '?') == 1 {
	if rest.ends_with('?') && !rest.trim_right('?').contains('?') {
		url.force_query = true
		rest = rest.left(rest.len-1)
	} else {
		parts := split(rest, '?', true)
		rest = parts[0]
		url.raw_query = parts[1]
	}

	if !rest.starts_with('/') {
		if url.scheme != '' {
			// We consider rootless paths per RFC 3986 as opaque.
			url.opaque = rest
			return url
		}
		if via_request {
			return error(error_msg('invalid URI for request', ''))
		}

		// Avoid confusion with malformed schemes, like cache_object:foo/bar.
		// See golang.org/issue/16822.
		//
		// RFC 3986, §3.3:
		// In addition, a URI reference (Section 4.1) may be a relative-path reference,
		// in which case the first path segment cannot contain a colon (':') character.
		colon := rest.index(':')
		slash := rest.index('/')
		if colon >= 0 && (slash < 0 || colon < slash) {
			// First path segment has colon. Not allowed in relative URL.
			return error(error_msg('first path segment in URL cannot contain colon', ''))
		}
	}

	if ((url.scheme != '' || !via_request) && !rest.starts_with('///')) && rest.starts_with('//') {
		parts := split(rest.right(2), '/', false)
		authority := parts[0]
		rest = parts[1]
		a := parse_authority(authority) or {
			return error(err)
		}
		url.user = a.user
		url.host = a.host
	}
	// Set path and, optionally, raw_path.
	// raw_path is a hint of the encoding of path. We don't want to set it if
	// the default escaping of path is equivalent, to help make sure that people
	// don't rely on it in general.
	_ := url.set_path(rest) or {
		return error(err)
	}
	return url
}

struct ParseAuthorityRes {
	user &Userinfo
	host string
}

fn parse_authority(authority string) ?ParseAuthorityRes {
	i := authority.last_index('@')
	mut host := ''
	mut user := user('')
	if i < 0 {
		h := parse_host(authority) or {
			return error(err)
		}
		host = h
	} else {
		h := parse_host(authority.right(i+1)) or {
			return error(err)
		}
		host = h
	}
	if i < 0 {
		return ParseAuthorityRes{host: host}
	}
	mut userinfo := authority.left(i)
	if !valid_userinfo(userinfo) {
		return error(error_msg('invalid userinfo', ''))
	}
	if !userinfo.contains(':') {
		u := unescape(userinfo, .encode_user_password) or {
			return error(err)
		}
		userinfo = u
		user = user(userinfo)
	} else {
		parts := split(userinfo, ':', true)
		mut username := parts[0]
		mut password := parts[1]
		u := unescape(username, .encode_user_password) or {
			return error(err)
		}
		username = u
		p := unescape(password, .encode_user_password) or {
			return error(err)
		}
		password = p
		user = user_password(username, password)
	}
	return ParseAuthorityRes{
		user: user
		host: host
	}
}

// parse_host parses host as an authority without user
// information. That is, as host[:port].
fn parse_host(host string) ?string {
	if host.starts_with('[') {
		// parse an IP-Literal in RFC 3986 and RFC 6874.
		// E.g., '[fe80::1]', '[fe80::1%25en0]', '[fe80::1]:80'.
		mut i := host.last_index(']')
		if i < 0 {
			return error(error_msg('missing \']\' in host', ''))
		}
		mut colon_port := host.right(i+1)
		if !valid_optional_port(colon_port) {
			return error(error_msg('invalid port $colon_port after host ', ''))
		}

		// RFC 6874 defines that %25 (%-encoded percent) introduces
		// the zone identifier, and the zone identifier can use basically
		// any %-encoding it likes. That's different from the host, which
		// can only %-encode non-ASCII bytes.
		// We do impose some restrictions on the zone, to avoid stupidity
		// like newlines.
		zone := host.left(i).index('%25')
		if zone >= 0 {
			host1 := unescape(host.left(zone), .encode_host) or {
				return err
			}
			host2 := unescape(host.substr(zone, i), .encode_zone) or {
				return err
			}
			host3 := unescape(host.right(i), .encode_host) or {
				return err
			}
			return host1 + host2 + host3
		} else {
			i = host.last_index(':')
			if i != -1 {
				colon_port = host.right(i)
				if !valid_optional_port(colon_port) {
					return error(error_msg('invalid port $colon_port after host ', ''))
				}
			}
		}
	}

	h := unescape(host, .encode_host) or {
		return err
	}
	return h
	//host = h
	//return host
}

// set_path sets the path and raw_path fields of the URL based on the provided
// escaped path p. It maintains the invariant that raw_path is only specified
// when it differs from the default encoding of the path.
// For example:
// - set_path('/foo/bar')   will set path='/foo/bar' and raw_path=''
// - set_path('/foo%2fbar') will set path='/foo/bar' and raw_path='/foo%2fbar'
// set_path will return an error only if the provided path contains an invalid
// escaping.
fn (u mut URL) set_path(p string) ?bool {
	path := unescape(p, .encode_path) or {
		return error(err)
	}
	u.path = path
	escp := escape(path, .encode_path)
	if p == escp {
		// Default encoding is fine.
		u.raw_path = ''
	} else {
		u.raw_path = p
	}
	return true
}

// escaped_path returns the escaped form of u.path.
// In general there are multiple possible escaped forms of any path.
// escaped_path returns u.raw_path when it is a valid escaping of u.path.
// Otherwise escaped_path ignores u.raw_path and computes an escaped
// form on its own.
// The String and request_uri methods use escaped_path to construct
// their results.
// In general, code should call escaped_path instead of
// reading u.raw_path directly.
fn (u &URL) escaped_path() string {
	if u.raw_path != '' && valid_encoded_path(u.raw_path) {
		p := unescape(u.raw_path, .encode_path)
		return u.raw_path
	}
	if u.path == '*' {
		return '*' // don't escape (Issue 11202)
	}
	return escape(u.path, .encode_path)
}

// valid_encoded_path reports whether s is a valid encoded path.
// It must not contain any bytes that require escaping during path encoding.
fn valid_encoded_path(s string) bool {
	for i := 0; i < s.len; i++ {
		// RFC 3986, Appendix A.
		// pchar = unreserved / pct-encoded / sub-delims / ':' / '@'.
		// should_escape is not quite compliant with the RFC,
		// so we check the sub-delims ourselves and let
		// should_escape handle the others.
		x := s[i]
		switch x {
		case `!`, `$`, `&`, `\\`, `(`, `)`, `*`, `+`, `,`, `;`, `=`, `:`, `@`:
			// ok
		case `[`, `]`:
			// ok - not specified in RFC 3986 but left alone by modern browsers
		case `%`:
			// ok - percent encoded, will decode
		default:
			if should_escape(s[i], .encode_path) {
				return false
			}
		}
	}
	return true
}

// valid_optional_port reports whether port is either an empty string
// or matches /^:\d*$/
fn valid_optional_port(port string) bool {
	if port == '' {
		return true
	}
	if port[0] != `:` {
		return false
	}
	for b in port.right(1) {
		if b < `0` || b > `9` {
			return false
		}
	}
	return true
}

// str reassembles the URL into a valid URL string.
// The general form of the result is one of:
//
//	scheme:opaque?query#fragment
//	scheme://userinfo@host/path?query#fragment
//
// If u.opaque is non-empty, String uses the first form;
// otherwise it uses the second form.
// Any non-ASCII characters in host are escaped.
// To obtain the path, String uses u.escaped_path().
//
// In the second form, the following rules apply:
//	- if u.scheme is empty, scheme: is omitted.
//	- if u.user is nil, userinfo@ is omitted.
//	- if u.host is empty, host/ is omitted.
//	- if u.scheme and u.host are empty and u.user is nil,
//	   the entire scheme://userinfo@host/ is omitted.
//	- if u.host is non-empty and u.path begins with a /,
//	   the form host/path does not add its own /.
//	- if u.raw_query is empty, ?query is omitted.
//	- if u.fragment is empty, #fragment is omitted.
pub fn (u &URL) str() string {
	mut buf := strings.new_builder(200)
	if u.scheme != '' {
		buf.write(u.scheme)
		buf.write(':')
	}
	if u.opaque != '' {
		buf.write(u.opaque)
	} else {
		if u.scheme != '' || u.host != '' || !u.user.empty() {
			if u.host != '' || u.path != '' || !u.user.empty() {
				buf.write('//')
			}
			if !u.user.empty() {
				buf.write(u.user.string())
				buf.write('@')
			}
			if u.host != '' {
				buf.write(escape(u.host, .encode_host))
			}
		}
		path := u.escaped_path()
		if path != '' && path[0] != `/` && u.host != '' {
			buf.write('/')
		}
		if buf.len == 0 {
			// RFC 3986 §4.2
			// A path segment that contains a colon character (e.g., 'this:that')
			// cannot be used as the first segment of a relative-path reference, as
			// it would be mistaken for a scheme name. Such a segment must be
			// preceded by a dot-segment (e.g., './this:that') to make a relative-
			// path reference.
			i := path.index(':')
			if i > -1 && path.left(i).index('/') == -1 {
				buf.write('./')
			}
		}
		buf.write(path)
	}
	if u.force_query || u.raw_query != '' {
		buf.write('?')
		buf.write(u.raw_query)
	}
	if u.fragment != '' {
		buf.write('#')
		buf.write(escape(u.fragment, .encode_fragment))
	}
	return buf.str()
}

// Values maps a string key to a list of values.
// It is typically used for query parameters and form values.
// Unlike in the http.Header map, the keys in a Values map
// are case-sensitive.


// parseQuery parses the URL-encoded query string and returns
// a map listing the values specified for each key.
// parseQuery always returns a non-nil map containing all the
// valid query parameters found; err describes the first decoding error
// encountered, if any.
//
// Query is expected to be a list of key=value settings separated by
// ampersands or semicolons. A setting without an equals sign is
// interpreted as a key set to an empty value.
pub fn parse_query(query string) ?Values {
	mut m := new_values()
	_ := _parse_query(mut m, query) or {
		return error(err)
	}
	return m
}

// parse_query_silent is the same as parse_query
// but any errors will be silent
fn parse_query_silent(query string) Values {
	mut m := new_values()
	_ := _parse_query(mut m, query)
	return m
}

fn _parse_query(m mut Values, query string) ?bool {
	mut had_error := false
	mut q := query
	for q != '' {
		mut key := q
		mut i := key.index_any('&;')
		if i >= 0 {
			q = key.right(i+1)
			key = key.left(i)
		} else {
			q = ''
		}
		if key == '' {
			continue
		}
		mut value := ''
		i = key.index('=')
		if  i >= 0 {
			value = key.right(i+1)
			key = key.left(i)
		}
		k := query_unescape(key) or {
			had_error = true
			continue
		}
		key = k
		
		v := query_unescape(value) or {
			had_error = true
			continue
		}
		value = v
		m.add(key, value)
	}
	if had_error {
		return error(error_msg('error parsing query string', ''))
	}
	return true
}

// encode encodes the values into ``URL encoded'' form
// ('bar=baz&foo=quux') sorted by key.
pub fn (v Values) encode() string {
	if v.size == 0 {
		return ''
	}
	mut buf := strings.new_builder(200)
	mut keys := []string
	for k, _ in v.data {
		keys << k
	}
	keys.sort()
	for k in keys {
		vs := v.data[k]
		key_kscaped := query_escape(k)
		for _, val in vs.data {
			if buf.len > 0 {
				buf.write('&')
			}
			buf.write(key_kscaped)
			buf.write('=')
			buf.write(query_escape(val))
		}
	}
	return buf.str()
}

// resolve_path applies special path segments from refs and applies
// them to base, per RFC 3986.
fn resolve_path(base, ref string) string {
	mut full := ''
	if ref == '' {
		full = base
	} else if ref[0] != `/` {
		i := base.last_index('/')
		full = base.left(i+1) + ref
	} else {
		full = ref
	}
	if full == '' {
		return ''
	}
	mut dst := []string
	src := full.split('/')
	for _, elem in src {
		switch elem {
		case '.':
			// drop
		case '..':
			if dst.len > 0 {
				dst = dst.left(dst.len-1)
			}
		default:
			dst << elem
		}
	}
	last := src[src.len-1]
	if last == '.' || last == '..' {
		// Add final slash to the joined path.
		dst <<  ''
	}
	return '/' + dst.join('/').trim_left('/')
}

// is_abs reports whether the URL is absolute.
// Absolute means that it has a non-empty scheme.
pub fn (u &URL) is_abs() bool {
	return u.scheme != ''
}

// parse parses a URL in the context of the receiver. The provided URL
// may be relative or absolute. parse returns nil, err on parse
// failure, otherwise its return value is the same as resolve_reference.
pub fn (u &URL) parse(ref string) ?URL {
	refurl := parse(ref) or {
		return error(err)
	}
	return u.resolve_reference(refurl)
}

// resolve_reference resolves a URI reference to an absolute URI from
// an absolute base URI u, per RFC 3986 Section 5.2. The URI reference
// may be relative or absolute. resolve_reference always returns a new
// URL instance, even if the returned URL is identical to either the
// base or reference. If ref is an absolute URL, then resolve_reference
// ignores base and returns a copy of ref.
pub fn (u &URL) resolve_reference(ref &URL) ?URL {
	mut url := *ref
	if ref.scheme == '' {
		url.scheme = u.scheme
	}
	if ref.scheme != '' || ref.host != '' || !ref.user.empty() {
		// The 'absoluteURI' or 'net_path' cases.
		// We can ignore the error from set_path since we know we provided a
		// validly-escaped path.
		url.set_path(resolve_path(ref.escaped_path(), ''))
		return url
	}
	if ref.opaque != '' {
		url.user = user('')
		url.host = ''
		url.path = ''
		return url
	}
	if ref.path == '' && ref.raw_query == '' {
		url.raw_query = u.raw_query
		if ref.fragment == '' {
			url.fragment = u.fragment
		}
	}
	// The 'abs_path' or 'rel_path' cases.
	url.host = u.host
	url.user = u.user
	url.set_path(resolve_path(u.escaped_path(), ref.escaped_path()))
	return url
}

// query parses raw_query and returns the corresponding values.
// It silently discards malformed value pairs.
// To check errors use parseQuery.
pub fn (u &URL) query() Values {
	v := parse_query_silent(u.raw_query)
	return v
}

// request_uri returns the encoded path?query or opaque?query
// string that would be used in an HTTP request for u.
pub fn (u &URL) request_uri() string {
	mut result := u.opaque
	if result == '' {
		result = u.escaped_path()
		if result == '' {
			result = '/'
		}
	} else {
		if result.starts_with('//') {
			result = u.scheme + ':' + result
		}
	}
	if u.force_query || u.raw_query != '' {
		result += '?' + u.raw_query
	}
	return result
}

// hostname returns u.host, stripping any valid port number if present.
//
// If the result is enclosed in square brackets, as literal IPv6 addresses are,
// the square brackets are removed from the result.
pub fn (u &URL) hostname() string {
	host_port := split_host_port(u.host)
	return host_port[0]
}

// port returns the port part of u.host, without the leading colon.
// If u.host doesn't contain a port, port returns an empty string.
pub fn (u &URL) port() string {
	host_port := split_host_port(u.host)
	return host_port[1]
}

// split_host_port separates host and port. If the port is not valid, it returns
// the entire input as host, and it doesn't check the validity of the host.
// Per RFC 3986, it requires ports to be numeric.
fn split_host_port(hostport string) []string {
	mut host := hostport
	mut port := ''
	
	colon := host.last_index(':')
	if colon != -1 && valid_optional_port(host.right(colon)) {
		port = host.right(colon+1)
		host = host.left(colon)
	}

	if host.starts_with('[') && host.ends_with(']') {
		host = host.substr(1, host.len-1)
	}

	return [host, port]
}

// valid_userinfo reports whether s is a valid userinfo string per RFC 3986
// Section 3.2.1:
//     userinfo    = *( unreserved / pct-encoded / sub-delims / ':' )
//     unreserved  = ALPHA / DIGIT / '-' / '.' / '_' / '~'
//     sub-delims  = '!' / '$' / '&' / ''' / '(' / ')'
//                   / '*' / '+' / ',' / ';' / '='
//
// It doesn't validate pct-encoded. The caller does that via fn unescape.
pub fn valid_userinfo(s string) bool {
	for r in s {
		if `A` <= r && r <= `Z` {
			continue
		}
		if `a` <= r && r <= `z` {
			continue
		}
		if `0` <= r && r <= `9` {
			continue
		}
		switch r {
		case `-`, `.`, `_`, `:`, `~`, `!`, `$`, `&`, `\\`,
			`(`, `)`, `*`, `+`, `,`, `;`, `=`, `%`, `@`:
			continue
		default:
			return false
		}
	}
	return true
}

// string_contains_ctl_byte reports whether s contains any ASCII control character.
fn string_contains_ctl_byte(s string) bool {
	for i := 0; i < s.len; i++ {
		b := s[i]
		if b < ` ` || b == 0x7f {
			return true
		}
	}
	return false
}

pub fn ishex(c byte) bool {
	if `0` <= c && c <= `9` {
		return true
	} else if `a` <= c && c <= `f` {
		return true
	} else if `A` <= c && c <= `F` {
		return true
	}
	return false
}

fn unhex(c byte) byte {
	if `0` <= c && c <= `9` {
		return c - `0`
	} else if `a` <= c && c <= `f` {
		return c - `a` + 10
	} else if `A` <= c && c <= `F` {
		return c - `A` + 10
	}
	return 0
}
