// Command udsize measures the EC2 user data that `spawn task run` (spawn v0.121.0) would send
// for a resolved TaskSpec. It calls spawn's own builders, in the order cmd/task.go and
// pkg/launcher/provision.go use them:
//
//	wrapper := taskproto.GenerateWrapper(spec, resultsPrefix, region, gpu, runID)
//	flush   := taskproto.GenerateFlushScript(spec, resultsPrefix, region, runID)
//	script  := launcher.BuildLinuxBootstrap({Username: default, TaskFlushScript: flush, Command: wrapper})
//	userData = launcher.EncodeLinuxUserData(script)   // gzip, then base64
//
// RunInstances limits user data to 16384 bytes *after* base64 decoding, i.e. the gzip stream.
// Output is JSON: {"bootstrap_bytes", "gzip_bytes", "base64_bytes"}. Placement storage scripts
// are not modelled; run.sh refuses specs that would need them.
package main

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/spore-host/spawn/pkg/launcher"
	"github.com/spore-host/spawn/pkg/taskproto"
)

func main() {
	region := flag.String("region", "", "launch region")
	account := flag.String("account", "", "AWS account id")
	flag.Parse()
	if flag.NArg() != 1 || *region == "" || *account == "" {
		fmt.Fprintln(os.Stderr, "usage: udsize -region R -account A spec.resolved.json")
		os.Exit(2)
	}
	spec, err := taskproto.ParseSpecFile(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, "udsize:", err)
		os.Exit(2)
	}
	prefix := taskproto.EffectiveResultsPrefix(spec, *account, *region)
	runID := "00000000-0000-0000-0000-000000000000" // uuid.NewString() length
	gpu := spec.Resources.GPUs > 0
	wrapper := taskproto.GenerateWrapper(spec, prefix, *region, gpu, runID)
	flush := taskproto.GenerateFlushScript(spec, prefix, *region, runID)
	script, err := launcher.BuildLinuxBootstrap(launcher.BootstrapConfig{
		Username:        launcher.DefaultUsername,
		TaskFlushScript: flush,
		Command:         wrapper,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "udsize:", err)
		os.Exit(2)
	}
	ud := launcher.EncodeLinuxUserData(script)
	raw, err := base64.StdEncoding.DecodeString(ud)
	if err != nil {
		fmt.Fprintln(os.Stderr, "udsize:", err)
		os.Exit(2)
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]int{
		"bootstrap_bytes": len(script), "gzip_bytes": len(raw), "base64_bytes": len(ud),
	})
}
