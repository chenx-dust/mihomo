package geodata

import (
	"os"
	"path/filepath"

	"github.com/metacubex/mihomo/component/geodata/router"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

func loadDomainMatcherCache(name string) (router.DomainMatcher, error) {
	path := filepath.Join(C.Path.MatcherCache(), "geosite_"+name+".bin")
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return router.ReadDomainMatcherBin(f)
}

func saveDomainMatcherCache(name string, m router.DomainMatcher) {
	if !C.SaveMatcherCache() {
		return
	}
	path := filepath.Join(C.Path.MatcherCache(), "geosite_"+name+".bin")
	f, err := os.Create(path)
	if err != nil {
		log.Warnln("Save GeoSite cache failed: %s, %v", name, err)
		return
	}
	defer f.Close()
	if err = router.WriteDomainMatcher(f, m); err != nil {
		log.Warnln("Save GeoSite cache failed: %s, %v", name, err)
		os.Remove(path)
	}
}

func loadIPMatcherCache(name string) (router.IPMatcher, error) {
	path := filepath.Join(C.Path.MatcherCache(), "geoip_"+name+".bin")
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return router.ReadIPMatcherBin(f)
}

func saveIPMatcherCache(name string, m router.IPMatcher) {
	if !C.SaveMatcherCache() {
		return
	}
	path := filepath.Join(C.Path.MatcherCache(), "geoip_"+name+".bin")
	f, err := os.Create(path)
	if err != nil {
		log.Warnln("Save GeoIP cache failed: %s, %v", name, err)
		return
	}
	defer f.Close()
	if err = router.WriteIPMatcher(f, m); err != nil {
		log.Warnln("Save GeoIP cache failed: %s, %v", name, err)
		os.Remove(path)
	}
}
