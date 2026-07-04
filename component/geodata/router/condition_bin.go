package router

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/metacubex/mihomo/component/cidr"
	"github.com/metacubex/mihomo/component/geodata/strmatcher"
	"github.com/metacubex/mihomo/component/trie"
)

func WriteDomainMatcher(w io.Writer, m DomainMatcher) error {
	sm, ok := m.(*succinctDomainMatcher)
	if !ok {
		return fmt.Errorf("only succinctDomainMatcher supports serialization")
	}
	return sm.WriteBin(w)
}

func WriteIPMatcher(w io.Writer, m IPMatcher) error {
	gm, ok := m.(*geoIPMatcher)
	if !ok {
		return fmt.Errorf("only geoIPMatcher supports serialization")
	}
	return gm.WriteBin(w)
}

func (m *succinctDomainMatcher) WriteBin(w io.Writer) (err error) {
	// version
	_, err = w.Write([]byte{1})
	if err != nil {
		return err
	}

	// count
	err = binary.Write(w, binary.BigEndian, int64(m.count))
	if err != nil {
		return err
	}

	// hasSet
	hasSet := m.set != nil
	err = binary.Write(w, binary.BigEndian, hasSet)
	if err != nil {
		return err
	}

	// set
	if hasSet {
		err = m.set.WriteBin(w)
		if err != nil {
			return err
		}
	}

	// otherMatchers
	err = binary.Write(w, binary.BigEndian, int64(len(m.otherMatchers)))
	if err != nil {
		return err
	}
	for _, matcher := range m.otherMatchers {
		s := matcher.String()
		err = binary.Write(w, binary.BigEndian, int64(len(s)))
		if err != nil {
			return err
		}
		_, err = io.WriteString(w, s)
		if err != nil {
			return err
		}
	}

	return nil
}

func ReadDomainMatcherBin(r io.Reader) (DomainMatcher, error) {
	// version
	version := make([]byte, 1)
	_, err := io.ReadFull(r, version)
	if err != nil {
		return nil, err
	}
	if version[0] != 1 {
		return nil, errors.New("version is invalid")
	}

	// count
	var count int64
	err = binary.Read(r, binary.BigEndian, &count)
	if err != nil {
		return nil, err
	}

	// hasSet
	var hasSet bool
	err = binary.Read(r, binary.BigEndian, &hasSet)
	if err != nil {
		return nil, err
	}

	// set
	var set *trie.DomainSet
	if hasSet {
		set, err = trie.ReadDomainSetBin(r)
		if err != nil {
			return nil, err
		}
	}

	// otherMatchers
	var length int64
	err = binary.Read(r, binary.BigEndian, &length)
	if err != nil {
		return nil, err
	}
	if length < 0 {
		return nil, errors.New("length is invalid")
	}
	otherMatchers := make([]strmatcher.Matcher, 0, length)
	for i := int64(0); i < length; i++ {
		var slen int64
		err = binary.Read(r, binary.BigEndian, &slen)
		if err != nil {
			return nil, err
		}
		if slen < 1 {
			return nil, errors.New("length is invalid")
		}
		buf := make([]byte, slen)
		_, err = io.ReadFull(r, buf)
		if err != nil {
			return nil, err
		}
		matcher, err := parseMatcherString(string(buf))
		if err != nil {
			return nil, err
		}
		otherMatchers = append(otherMatchers, matcher)
	}

	return &succinctDomainMatcher{
		set:           set,
		otherMatchers: otherMatchers,
		count:         int(count),
	}, nil
}

func (m *geoIPMatcher) WriteBin(w io.Writer) (err error) {
	// version
	_, err = w.Write([]byte{1})
	if err != nil {
		return err
	}

	// count
	err = binary.Write(w, binary.BigEndian, int64(m.count))
	if err != nil {
		return err
	}

	// cidrSet
	err = m.cidrSet.WriteBin(w)
	if err != nil {
		return err
	}

	return nil
}

func ReadIPMatcherBin(r io.Reader) (IPMatcher, error) {
	// version
	version := make([]byte, 1)
	_, err := io.ReadFull(r, version)
	if err != nil {
		return nil, err
	}
	if version[0] != 1 {
		return nil, errors.New("version is invalid")
	}

	// count
	var count int64
	err = binary.Read(r, binary.BigEndian, &count)
	if err != nil {
		return nil, err
	}

	// cidrSet
	cidrSet, err := cidr.ReadIpCidrSet(r)
	if err != nil {
		return nil, err
	}

	return &geoIPMatcher{
		cidrSet: cidrSet,
		count:   int(count),
	}, nil
}

var matcherPrefixMap = map[string]strmatcher.Type{
	"full":    strmatcher.Full,
	"keyword": strmatcher.Substr,
	"domain":  strmatcher.Domain,
	"regexp":  strmatcher.Regex,
}

func parseMatcherString(s string) (strmatcher.Matcher, error) {
	idx := strings.IndexByte(s, ':')
	if idx < 0 {
		return nil, errors.New("invalid matcher string: missing type prefix")
	}
	typ, ok := matcherPrefixMap[s[:idx]]
	if !ok {
		return nil, errors.New("invalid matcher string: unknown type prefix")
	}
	return typ.New(s[idx+1:])
}
