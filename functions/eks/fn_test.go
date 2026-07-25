package main

import (
	"context"
	"testing"

	"github.com/google/go-cmp/cmp"
	"github.com/google/go-cmp/cmp/cmpopts"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/testing/protocmp"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
)

func TestRunFunction(t *testing.T) {
	type args struct {
		ctx context.Context
		req *fnv1.RunFunctionRequest
	}
	type want struct {
		rsp *fnv1.RunFunctionResponse
		err error
	}

	cases := map[string]struct {
		reason string
		args   args
		want   want
	}{}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			f := &Function{log: logging.NewNopLogger()}
			rsp, err := f.RunFunction(tc.args.ctx, tc.args.req)

			if diff := cmp.Diff(tc.want.rsp, rsp, protocmp.Transform()); diff != "" {
				t.Errorf("%s\nf.RunFunction(...): -want rsp, +got rsp:\n%s", tc.reason, diff)
			}

			if diff := cmp.Diff(tc.want.err, err, cmpopts.EquateErrors()); diff != "" {
				t.Errorf("%s\nf.RunFunction(...): -want err, +got err:\n%s", tc.reason, diff)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// RunFunction scenario tests (mirror tests/test-eks-import acceptance gates).
// These exercise the full port end-to-end without the up/crossplane runtime;
// the runtime-added crossplane.io/composition-resource-name annotation is
// represented here by the desired-resources map key.
// ---------------------------------------------------------------------------

func mustStruct(t *testing.T, j string) *structpb.Struct {
	t.Helper()
	s := &structpb.Struct{}
	if err := protojson.Unmarshal([]byte(j), s); err != nil {
		t.Fatalf("bad json: %v", err)
	}
	return s
}

func runImport(t *testing.T, xrJSON string, observed map[string]*fnv1.Resource) *fnv1.RunFunctionResponse {
	t.Helper()
	xr := mustStruct(t, xrJSON)
	req := &fnv1.RunFunctionRequest{
		Observed: &fnv1.State{
			Composite: &fnv1.Resource{Resource: xr},
			Resources: observed,
		},
		Desired: &fnv1.State{
			Composite: &fnv1.Resource{Resource: xr},
		},
	}
	f := &Function{log: logging.NewNopLogger()}
	rsp, err := f.RunFunction(context.Background(), req)
	if err != nil {
		t.Fatalf("RunFunction error: %v", err)
	}
	return rsp
}

const xrObserveJSON = `{
  "apiVersion":"aws.platform.upbound.io/v1alpha1","kind":"EKS",
  "metadata":{"name":"imported-eks","namespace":"default"},
  "spec":{"parameters":{
    "id":"imported-eks","region":"us-west-2","version":"1.34",
    "accessConfig":{"authenticationMode":"API_AND_CONFIG_MAP","bootstrapClusterCreatorAdminPermissions":true},
    "nodes":{"count":1,"instanceType":"t3.small"},
    "providerConfigName":"default",
    "import":{"commit":false,"resources":{
      "kubernetesCluster":"imported-eks-cluster",
      "controlplaneRole":"imported-eks-controlplane-role",
      "nodegroupRole":"imported-eks-nodegroup-role",
      "ebsCSIDriverRole":"imported-eks-ebs-csi-role",
      "nodeGroupPublic":"imported-ng",
      "vpcCniAddon":"imported-eks-cluster:vpc-cni",
      "ebsCsiAddon":"imported-eks-cluster:aws-ebs-csi-driver",
      "podIdentityAgentAddon":"imported-eks-cluster:eks-pod-identity-agent",
      "ebsCSIDriverPodIdentityAssociation":"a-abc1234567890abc"
    }}
  }}
}`

func observedClusterAndAddon(t *testing.T) map[string]*fnv1.Resource {
	cluster := mustStruct(t, `{
      "apiVersion":"eks.aws.m.upbound.io/v1beta1","kind":"Cluster",
      "metadata":{"name":"imported-eks-cluster","namespace":"default"},
      "spec":{"forProvider":{"region":"us-west-2","version":"1.34",
        "tags":{"crossplane-kind":"cluster.eks.aws.m.upbound.io","crossplane-name":"imported-eks-cluster","crossplane-providerconfig":"default"},
        "vpcConfig":{"endpointPrivateAccess":true}}},
      "status":{"atProvider":{"version":"1.33","accessConfig":{"authenticationMode":"API_AND_CONFIG_MAP"},
        "tags":{"Name":"eksctl-imported/ControlPlane","alpha.eksctl.io/cluster-name":"imported-eks-cluster"},
        "vpcConfig":{"endpointPrivateAccess":false}}}
    }`)
	addon := mustStruct(t, `{
      "apiVersion":"eks.aws.m.upbound.io/v1beta1","kind":"Addon",
      "metadata":{"name":"imported-vpc-cni","namespace":"default"},
      "spec":{"forProvider":{"configurationValues":"{\"env\": {\"B\": \"2\", \"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG\": \"false\"}}"}},
      "status":{"atProvider":{"configurationValues":"{\n  \"env\": {\n    \"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG\": \"false\",\n    \"B\": \"2\"\n  }\n}"}}
    }`)
	return map[string]*fnv1.Resource{
		"kubernetesCluster": {Resource: cluster},
		"vpc-cni-addon":     {Resource: addon},
	}
}

func TestRunFunctionImportObserve(t *testing.T) {
	rsp := runImport(t, xrObserveJSON, observedClusterAndAddon(t))

	// Cluster rendered observe-only with external name pinned.
	cl, ok := rsp.GetDesired().GetResources()["kubernetesCluster"]
	if !ok {
		t.Fatal("kubernetesCluster not in desired resources")
	}
	clm := cl.GetResource().AsMap()
	if got := digStr(clm, "metadata", "annotations", "crossplane.io/external-name"); got != "imported-eks-cluster" {
		t.Errorf("external-name = %q, want imported-eks-cluster", got)
	}
	mp := dig(clm, "spec", "managementPolicies")
	if s, _ := mp.([]any); len(s) != 2 || s[0] != "Observe" || s[1] != "LateInitialize" {
		t.Errorf("managementPolicies = %v, want [Observe LateInitialize]", mp)
	}
	if got := digStr(clm, "spec", "forProvider", "region"); got != "us-west-2" {
		t.Errorf("region = %q", got)
	}

	// status.import
	imp := dig(rsp.GetDesired().GetComposite().GetResource().AsMap(), "status", "import")
	m, _ := imp.(map[string]any)
	if m["active"] != true || m["commit"] != false || m["phase"] != "Observing" {
		t.Errorf("import header = %v", m)
	}
	if dc, _ := m["driftCount"].(float64); dc != 1 {
		t.Errorf("driftCount = %v, want 1", m["driftCount"])
	}
	if sc, _ := m["sideEffectCount"].(float64); sc != 6 {
		t.Errorf("sideEffectCount = %v, want 6", m["sideEffectCount"])
	}
	if miss, _ := m["missing"].([]any); len(miss) != 0 {
		t.Errorf("missing = %v, want []", m["missing"])
	}
	kc := dig(m, "resources", "kubernetesCluster")
	kcm, _ := kc.(map[string]any)
	if kcm["externalName"] != "imported-eks-cluster" || kcm["observed"] != true {
		t.Errorf("kubernetesCluster entry = %v", kcm)
	}
	drift, _ := kcm["drift"].([]any)
	if len(drift) != 1 {
		t.Fatalf("drift = %v, want 1 entry", drift)
	}
	d0, _ := drift[0].(map[string]any)
	if d0["field"] != "version" || d0["desired"] != "1.34" || d0["observed"] != "1.33" {
		t.Errorf("drift[0] = %v", d0)
	}
}

func TestRunFunctionImportMissing(t *testing.T) {
	xr := `{
      "apiVersion":"aws.platform.upbound.io/v1alpha1","kind":"EKS",
      "metadata":{"name":"imported-eks","namespace":"default"},
      "spec":{"parameters":{
        "id":"imported-eks","region":"us-west-2","version":"1.34",
        "accessConfig":{"authenticationMode":"API_AND_CONFIG_MAP","bootstrapClusterCreatorAdminPermissions":true},
        "nodes":{"count":1,"instanceType":"t3.small"},"providerConfigName":"default",
        "import":{"commit":false,"resources":{
          "controlplaneRole":"imported-eks-controlplane-role",
          "nodegroupRole":"imported-eks-nodegroup-role"
        }}
      }}
    }`
	rsp := runImport(t, xr, nil)

	// blockRender: no composed resources emitted.
	if n := len(rsp.GetDesired().GetResources()); n != 0 {
		t.Errorf("expected 0 composed resources on blockRender, got %d", n)
	}
	imp := dig(rsp.GetDesired().GetComposite().GetResource().AsMap(), "status", "import")
	m, _ := imp.(map[string]any)
	if m["error"] == nil {
		t.Errorf("expected error string on blockRender")
	}
	want := []string{"ebsCSIDriverRole", "kubernetesCluster", "nodeGroupPublic", "vpcCniAddon", "ebsCsiAddon", "podIdentityAgentAddon", "ebsCSIDriverPodIdentityAssociation"}
	miss, _ := m["missing"].([]any)
	if len(miss) != len(want) {
		t.Fatalf("missing = %v, want %v", miss, want)
	}
	for i, w := range want {
		if miss[i] != w {
			t.Errorf("missing[%d] = %v, want %s", i, miss[i], w)
		}
	}
}

func TestRunFunctionImportCommit(t *testing.T) {
	xr := `{
      "apiVersion":"aws.platform.upbound.io/v1alpha1","kind":"EKS",
      "metadata":{"name":"imported-eks","namespace":"default"},
      "spec":{"parameters":{
        "id":"imported-eks","region":"us-west-2","version":"1.34",
        "accessConfig":{"authenticationMode":"API_AND_CONFIG_MAP","bootstrapClusterCreatorAdminPermissions":true},
        "nodes":{"count":1,"instanceType":"t3.small"},"providerConfigName":"default",
        "import":{"commit":true,"resources":{
          "kubernetesCluster":"imported-eks-cluster","controlplaneRole":"imported-eks-controlplane-role",
          "nodegroupRole":"imported-eks-nodegroup-role","ebsCSIDriverRole":"imported-eks-ebs-csi-role",
          "nodeGroupPublic":"imported-ng","vpcCniAddon":"imported-eks-cluster:vpc-cni",
          "ebsCsiAddon":"imported-eks-cluster:aws-ebs-csi-driver","podIdentityAgentAddon":"imported-eks-cluster:eks-pod-identity-agent",
          "ebsCSIDriverPodIdentityAssociation":"a-abc1234567890abc"
        }}
      }}
    }`
	rsp := runImport(t, xr, nil)
	cl := rsp.GetDesired().GetResources()["kubernetesCluster"]
	if cl == nil {
		t.Fatal("kubernetesCluster missing")
	}
	clm := cl.GetResource().AsMap()
	mp, _ := dig(clm, "spec", "managementPolicies").([]any)
	if len(mp) != 1 || mp[0] != "*" {
		t.Errorf("managementPolicies = %v, want [*]", mp)
	}
	if got := digStr(clm, "metadata", "annotations", "crossplane.io/external-name"); got != "imported-eks-cluster" {
		t.Errorf("external-name = %q", got)
	}
	imp, _ := dig(rsp.GetDesired().GetComposite().GetResource().AsMap(), "status", "import").(map[string]any)
	if imp["commit"] != true || imp["phase"] != "Committing" {
		t.Errorf("import = %v, want commit/Committing", imp)
	}
}

func dig(m map[string]any, keys ...string) any {
	var cur any = m
	for _, k := range keys {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[k]
	}
	return cur
}

func digStr(m map[string]any, keys ...string) string {
	s, _ := dig(m, keys...).(string)
	return s
}
