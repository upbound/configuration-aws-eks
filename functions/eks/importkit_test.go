package main

import (
	"reflect"
	"testing"
)

// ---------------------------------------------------------------------------
// 1. managementPolicies
// ---------------------------------------------------------------------------

func TestManagementPolicies(t *testing.T) {
	def := []string{"*", "!Delete"}
	cases := []struct {
		name         string
		importActive bool
		commit       bool
		def          []string
		want         []string
	}{
		{"importing-not-committed", true, false, def, []string{"Observe", "LateInitialize"}},
		{"importing-committed", true, true, def, []string{"*"}},
		{"not-importing-passthrough", false, false, def, def},
		{"not-importing-committed-passthrough", false, true, def, def},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := managementPolicies(tc.importActive, tc.commit, tc.def)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("managementPolicies(%v,%v) = %v, want %v", tc.importActive, tc.commit, got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// 2. JSON normalization (reordered + whitespaced but semantically identical)
// ---------------------------------------------------------------------------

func TestJSONNormalizationNoChange(t *testing.T) {
	a := `{"env": {"B": "2", "AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG": "false"}}`
	b := "{\n  \"env\": {\n    \"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG\": \"false\",\n    \"B\": \"2\"\n  }\n}"

	if !jsonEqual(a, b) {
		t.Fatalf("jsonEqual should be true for semantically identical JSON")
	}
	desired := map[string]any{"configurationValues": a}
	observed := map[string]any{"configurationValues": b}
	got := diff(desired, observed)
	if len(got) != 0 {
		t.Fatalf("expected NO change for reordered/whitespaced JSON, got %d: %+v", len(got), got)
	}
}

// ---------------------------------------------------------------------------
// 3. _looksJson structural detection
// ---------------------------------------------------------------------------

func TestLooksJson(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{`{"a":1}`, true},
		{`{}`, true},
		{`{ "x"`, true},
		{`[1,2]`, false},
		{`hello`, false},
		{`{{ .Values }}`, false},
		{`  {"y":2}`, true},
	}
	for _, tc := range cases {
		if got := looksJson(tc.in); got != tc.want {
			t.Errorf("looksJson(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

// ---------------------------------------------------------------------------
// 4. Scalar-list order-insensitivity
// ---------------------------------------------------------------------------

func TestScalarListOrderInsensitive(t *testing.T) {
	desired := map[string]any{"subnetIds": []any{"a", "b", "c"}}
	observed := map[string]any{"subnetIds": []any{"c", "a", "b"}}
	got := diff(desired, observed)
	if len(got) != 0 {
		t.Fatalf("expected NO change for reordered scalar list, got %d: %+v", len(got), got)
	}

	// sanity: a genuinely different set IS a change
	got2 := diff(
		map[string]any{"subnetIds": []any{"a", "b", "c"}},
		map[string]any{"subnetIds": []any{"a", "b", "d"}},
	)
	if len(got2) != 1 {
		t.Fatalf("expected 1 change for differing scalar list, got %d: %+v", len(got2), got2)
	}
}

// sameSet edge: length-equal + mutual set membership (NOT multiset) — replicate
// KCL exactly. ["a","a","b"] vs ["a","b","b"] are reported EQUAL.
func TestSameSetMultisetQuirk(t *testing.T) {
	if !sameSet([]any{"a", "a", "b"}, []any{"a", "b", "b"}) {
		t.Fatalf("sameSet should report equal (KCL length+mutual-membership semantics)")
	}
	if sameSet([]any{"a", "a"}, []any{"a", "b"}) {
		t.Fatalf("sameSet should report NOT equal: b not a member of [a,a]")
	}
	if sameSet([]any{"a"}, []any{"a", "b"}) {
		t.Fatalf("sameSet should report NOT equal: differing length")
	}
}

// ---------------------------------------------------------------------------
// 5. tags map diff: 2 removals + 3 additions = 5 entries
// ---------------------------------------------------------------------------

func TestTagsMapDiff(t *testing.T) {
	desired := map[string]any{
		"tags": map[string]any{
			"crossplane-kind":           "x",
			"crossplane-name":           "y",
			"crossplane-providerconfig": "z",
		},
	}
	observed := map[string]any{
		"tags": map[string]any{
			"Name":                         "my-cluster",
			"alpha.eksctl.io/cluster-name": "my-cluster",
		},
	}
	got := diff(desired, observed)
	if len(got) != 5 {
		t.Fatalf("expected 5 tag changes (2 removals + 3 additions), got %d: %+v", len(got), got)
	}

	removals, additions := 0, 0
	for _, c := range got {
		switch {
		case c.HasObserved && !c.HasDesired:
			removals++
		case c.HasDesired && !c.HasObserved:
			additions++
		default:
			t.Errorf("unexpected change shape (both/neither present): %+v", c)
		}
	}
	if removals != 2 || additions != 3 {
		t.Fatalf("expected 2 removals + 3 additions, got %d removals / %d additions", removals, additions)
	}
}

// ---------------------------------------------------------------------------
// 6. Full observe-phase scenario: driftCount=1 / sideEffectCount=6
//    (mirrors tests/test-eks-import acceptance gate)
// ---------------------------------------------------------------------------

func resource(fp, ap map[string]any) map[string]any {
	return map[string]any{
		"Resource": map[string]any{
			"spec":   map[string]any{"forProvider": fp},
			"status": map[string]any{"atProvider": ap},
		},
	}
}

func TestObservePhaseScenario(t *testing.T) {
	addonA := `{"env": {"B": "2", "AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG": "false"}}`
	addonB := "{\n  \"env\": {\n    \"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG\": \"false\",\n    \"B\": \"2\"\n  }\n}"

	clusterFP := map[string]any{
		"region":  "us-west-2",
		"version": "1.34",
		"tags": map[string]any{
			"crossplane-kind":           "cluster.eks.aws",
			"crossplane-name":           "my-cluster",
			"crossplane-providerconfig": "default",
		},
		"vpcConfig": map[string]any{
			"endpointPrivateAccess": true,
		},
	}
	clusterAP := map[string]any{
		"version": "1.33",
		"accessConfig": map[string]any{
			"authenticationMode": "API_AND_CONFIG_MAP",
		},
		"tags": map[string]any{
			"Name":                         "my-cluster",
			"alpha.eksctl.io/cluster-name": "my-cluster",
		},
		"vpcConfig": map[string]any{
			"endpointPrivateAccess": false,
		},
	}

	addonFP := map[string]any{"configurationValues": addonA}
	addonAP := map[string]any{"configurationValues": addonB}

	ocds := map[string]any{
		"kubernetesCluster": resource(clusterFP, clusterAP),
		"vpc-cni-addon":     resource(addonFP, addonAP),
	}

	cfg := ReportConfig{
		OCDS: ocds,
		ImportResources: map[string]any{
			"kubernetesCluster": "my-cluster",
			"vpcCniAddon":       "vpc-cni",
		},
		Registry: map[string]string{
			"kubernetesCluster": "kubernetesCluster",
			"vpcCniAddon":       "vpc-cni-addon",
		},
		Reconcilable: []string{"version", "authenticationMode", "instanceTypes", "desiredSize", "subnetIds"},
		RequiredKeys: []string{},
	}

	rep := buildReport(cfg)

	if rep.BlockRender {
		t.Fatalf("expected blockRender=false, got true (missing=%v)", rep.Missing)
	}

	// Cluster drift = exactly [{version, 1.34, 1.33}]
	cluster, ok := rep.Resources["kubernetesCluster"]
	if !ok {
		t.Fatalf("expected kubernetesCluster in resources")
	}
	if len(cluster.Drift) != 1 {
		t.Fatalf("expected cluster drift len 1, got %d: %+v", len(cluster.Drift), cluster.Drift)
	}
	d := cluster.Drift[0]
	if d.Field != "version" || d.Desired != "1.34" || d.Observed != "1.33" {
		t.Fatalf("unexpected cluster drift entry: %+v", d)
	}
	if !cluster.Observed {
		t.Fatalf("expected cluster.Observed=true")
	}

	// vpc-cni addon: JSON is semantically identical -> 0 changes
	addon := rep.Resources["vpcCniAddon"]
	if len(addon.Drift)+len(addon.SideEffects) != 0 {
		t.Fatalf("expected addon to contribute 0 changes, got drift=%d side=%d", len(addon.Drift), len(addon.SideEffects))
	}

	// Acceptance gate: driftCount=1, sideEffectCount=6
	if rep.DriftCount != 1 {
		t.Fatalf("expected driftCount=1, got %d", rep.DriftCount)
	}
	if rep.SideEffectCount != 6 {
		t.Fatalf("expected sideEffectCount=6 (2 tag removes + 3 tag adds + endpointPrivateAccess), got %d: %+v",
			rep.SideEffectCount, cluster.SideEffects)
	}

	// Verify the side-effect composition explicitly.
	tagChanges, epa := 0, 0
	for _, c := range cluster.SideEffects {
		switch {
		case c.Field == "vpcConfig.endpointPrivateAccess":
			epa++
			if c.Desired != true || c.Observed != false {
				t.Errorf("unexpected endpointPrivateAccess change: %+v", c)
			}
		case len(c.Field) >= 5 && c.Field[:5] == "tags[":
			tagChanges++
		default:
			t.Errorf("unexpected side effect: %+v", c)
		}
	}
	if tagChanges != 5 || epa != 1 {
		t.Fatalf("expected 5 tag side-effects + 1 endpointPrivateAccess, got %d tags / %d epa", tagChanges, epa)
	}
}

// ---------------------------------------------------------------------------
// Extra guards for subtle semantics
// ---------------------------------------------------------------------------

// _skipKey suppresses cross-resource wiring keys and tagsAll.
func TestSkipKeys(t *testing.T) {
	desired := map[string]any{
		"roleArnRef":       map[string]any{"name": "a"},
		"subnetIdRefs":     []any{"x"},
		"subnetIdSelector": map[string]any{"matchLabels": map[string]any{"k": "v"}},
		"tagsAll":          map[string]any{"a": "b"},
		"region":           "us-west-2",
	}
	observed := map[string]any{
		"roleArnRef":       map[string]any{"name": "different"},
		"subnetIdRefs":     []any{"y"},
		"subnetIdSelector": map[string]any{"matchLabels": map[string]any{"k": "other"}},
		"tagsAll":          map[string]any{"a": "c"},
		"region":           "eu-central-1",
	}
	got := diff(desired, observed)
	if len(got) != 1 || got[0].Field != "region" {
		t.Fatalf("expected only 'region' change (skip keys suppressed), got %+v", got)
	}
}

// Absent observed subtree is not a committable change.
func TestAbsentObservedNoChange(t *testing.T) {
	desired := map[string]any{
		"vpcConfig":   map[string]any{"endpointPrivateAccess": true},
		"onlyDesired": "value",
	}
	observed := map[string]any{} // nothing reported
	got := diff(desired, observed)
	if len(got) != 0 {
		t.Fatalf("expected NO change when observed reports nothing, got %+v", got)
	}
}

// JSON decode is never attempted on non-JSON strings ([-arrays, plain text).
func TestNonJsonStringsCompareLiterally(t *testing.T) {
	// "[INFO] ..." must NOT be treated as JSON; literal inequality => change.
	got := diff(
		map[string]any{"log": "[INFO] a"},
		map[string]any{"log": "[INFO] b"},
	)
	if len(got) != 1 {
		t.Fatalf("expected 1 change for differing non-JSON strings, got %+v", got)
	}
	// Identical non-JSON strings => no change.
	got2 := diff(
		map[string]any{"log": "[INFO] a"},
		map[string]any{"log": "[INFO] a"},
	)
	if len(got2) != 0 {
		t.Fatalf("expected 0 changes for identical non-JSON strings, got %+v", got2)
	}
}
