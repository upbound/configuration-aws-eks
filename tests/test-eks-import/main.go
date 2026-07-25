// Package main generates the brownfield import CompositionTest suite.
//
// It validates the import lifecycle driven from spec.parameters.import:
//   - observe:  external-name pinned, managementPolicies forced to observe-only,
//     and status.import drift report computed from observed atProvider.
//   - missing:  a non-empty import.resources that omits required keys blocks the
//     render and reports status.import.missing + error.
//   - commit:   import.commit=true switches managementPolicies to ["*"] while the
//     external-name stays pinned.
//
// The composite (EKS) status assertions are expressed as map[string]any literals
// (mirroring the KCL source, where `import` is a reserved keyword and cannot be a
// schema attribute identifier).
package main

import (
	"encoding/json"
	"fmt"
	"os"

	metav1 "dev.upbound.io/models/io/k8s/meta/v1"
	metav1alpha1 "dev.upbound.io/models/io/upbound/dev/meta/v1alpha1"
	eksv1beta1 "dev.upbound.io/models/io/upbound/m/aws/eks/v1beta1"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/yaml"
)

// commonSpec returns the fields shared by every CompositionTest case.
func commonSpec() metav1alpha1.CompositionTestSpec {
	return metav1alpha1.CompositionTestSpec{
		CompositionPath: ptr.To("apis/eks/composition.yaml"),
		XrdPath:         ptr.To("apis/eks/definition.yaml"),
		TimeoutSeconds:  ptr.To(60),
		Validate:        ptr.To(false),
	}
}

// observedCluster is the live EKS Cluster observed during the observe phase.
// The XR wants version 1.34; the live cluster reports 1.33 -> one drift entry.
func observedCluster() eksv1beta1.Cluster {
	return eksv1beta1.Cluster{
		APIVersion: ptr.To(eksv1beta1.ClusterAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.ClusterKindCluster),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "kubernetesCluster",
			}),
			Name:      ptr.To("imported-eks-cluster"),
			Namespace: ptr.To("default"),
		},
		Spec: &eksv1beta1.ClusterSpec{
			ForProvider: &eksv1beta1.ClusterSpecForProvider{
				Region: ptr.To("us-west-2"),
				// Desired version (composition renders params.version into
				// forProvider); the live cluster is a minor behind -> reconcilable drift.
				Version: ptr.To("1.34"),
				// Desired tags = the provider-injected crossplane-* defaults (the
				// composition itself sets no tags on the cluster).
				Tags: ptr.To(map[string]string{
					"crossplane-kind":           "cluster.eks.aws.m.upbound.io",
					"crossplane-name":           "imported-eks-cluster",
					"crossplane-providerconfig": "default",
				}),
				VpcConfig: &eksv1beta1.ClusterSpecForProviderVpcConfig{
					EndpointPrivateAccess: ptr.To(true),
				},
			},
		},
		Status: &eksv1beta1.ClusterStatus{
			AtProvider: &eksv1beta1.ClusterStatusAtProvider{
				Version: ptr.To("1.33"),
				AccessConfig: &eksv1beta1.ClusterStatusAtProviderAccessConfig{
					AuthenticationMode: ptr.To("API_AND_CONFIG_MAP"),
				},
				// Live tags come from the out-of-band tool (e.g. eksctl); committing
				// would strip these (2 removes) and add the 3 crossplane-* tags.
				Tags: ptr.To(map[string]string{
					"Name":                         "eksctl-imported/ControlPlane",
					"alpha.eksctl.io/cluster-name": "imported-eks-cluster",
				}),
				VpcConfig: &eksv1beta1.ClusterStatusAtProviderVpcConfig{
					EndpointPrivateAccess: ptr.To(false),
				},
			},
		},
	}
}

// observedVpcCniAddon is a raw-dict Addon whose configurationValues JSON strings
// are semantically identical but differently whitespaced AND key-ordered.
// Structural JSON-normalization must treat this as NO change, so it must not
// appear in drift or sideEffects. Without normalization it would inflate
// sideEffectCount to 7. Modeled as a map[string]any so the exact JSON strings
// (including the escaped whitespace/newlines) survive byte-for-byte.
func observedVpcCniAddon() map[string]any {
	return map[string]any{
		"apiVersion": "eks.aws.m.upbound.io/v1beta1",
		"kind":       "Addon",
		"metadata": map[string]any{
			"annotations": map[string]any{
				"crossplane.io/composition-resource-name": "vpc-cni-addon",
			},
			"name":      "imported-vpc-cni",
			"namespace": "default",
		},
		"spec": map[string]any{
			"forProvider": map[string]any{
				"configurationValues": `{"env": {"B": "2", "AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG": "false"}}`,
			},
		},
		"status": map[string]any{
			"atProvider": map[string]any{
				"configurationValues": "{\n  \"env\": {\n    \"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG\": \"false\",\n    \"B\": \"2\"\n  }\n}",
			},
		},
	}
}

// observeAssertCluster is the Cluster rendered observe-only with the external
// name pinned (the observe-phase assertion).
func observeAssertCluster() eksv1beta1.Cluster {
	return eksv1beta1.Cluster{
		APIVersion: ptr.To(eksv1beta1.ClusterAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.ClusterKindCluster),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "kubernetesCluster",
				"crossplane.io/external-name":             "imported-eks-cluster",
			}),
			// render assigns the observed resource's name to the desired resource
			Name:      ptr.To("imported-eks-cluster"),
			Namespace: ptr.To("default"),
		},
		Spec: &eksv1beta1.ClusterSpec{
			ManagementPolicies: &[]eksv1beta1.ClusterSpecManagementPoliciesItem{
				eksv1beta1.ClusterSpecManagementPoliciesItemClusterSpecManagementPoliciesItemObserve,
				eksv1beta1.ClusterSpecManagementPoliciesItemClusterSpecManagementPoliciesItemLateInitialize,
			},
			ForProvider: &eksv1beta1.ClusterSpecForProvider{
				Region: ptr.To("us-west-2"),
			},
		},
	}
}

// commitAssertCluster is the Cluster with full management taken while the
// external name stays pinned (the commit-phase assertion).
func commitAssertCluster() eksv1beta1.Cluster {
	return eksv1beta1.Cluster{
		APIVersion: ptr.To(eksv1beta1.ClusterAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.ClusterKindCluster),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "kubernetesCluster",
				"crossplane.io/external-name":             "imported-eks-cluster",
			}),
		},
		Spec: &eksv1beta1.ClusterSpec{
			ManagementPolicies: &[]eksv1beta1.ClusterSpecManagementPoliciesItem{
				eksv1beta1.ClusterSpecManagementPoliciesItemClusterSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.ClusterSpecForProvider{
				Region: ptr.To("us-west-2"),
			},
		},
	}
}

// compositeStatusImport wraps a status.import blob into a full composite EKS
// assertion. `import` is a KCL keyword, so the blob is a plain map here too.
func compositeStatusImport(importBlob map[string]any) map[string]any {
	return map[string]any{
		"apiVersion": "aws.platform.upbound.io/v1alpha1",
		"kind":       "EKS",
		"metadata": map[string]any{
			"name":      "imported-eks",
			"namespace": "default",
		},
		"status": map[string]any{
			"import": importBlob,
		},
	}
}

func observeTest() metav1alpha1.CompositionTest {
	spec := commonSpec()
	spec.XrPath = ptr.To("tests/test-eks-import/xr-observe.yaml")

	observedResources := resourcesToItems[metav1alpha1.CompositionTestSpecObservedResourcesItem](
		observedCluster(),
		observedVpcCniAddon(),
	)
	spec.ObservedResources = &observedResources

	assertResources := resourcesToItems[metav1alpha1.CompositionTestSpecAssertResourcesItem](
		observeAssertCluster(),
		// Composite status.import shows the observe phase and the version drift.
		compositeStatusImport(map[string]any{
			"active":  true,
			"commit":  false,
			"phase":   "Observing",
			"missing": []any{},
			// Generic forProvider-vs-atProvider diff: version is the only
			// reconcilable (param-backed) change.
			"driftCount": 1,
			// 2 eksctl tags removed + 3 crossplane-* tags added +
			// endpointPrivateAccess false->true = 6 non-reconcilable changes
			// committing would make beyond reconcilable drift.
			"sideEffectCount": 6,
			"resources": map[string]any{
				"kubernetesCluster": map[string]any{
					"externalName": "imported-eks-cluster",
					"observed":     true,
					"drift": []any{
						map[string]any{"field": "version", "desired": "1.34", "observed": "1.33"},
					},
				},
			},
		}),
	)
	spec.AssertResources = &assertResources

	return metav1alpha1.CompositionTest{
		APIVersion: ptr.To(metav1alpha1.CompositionTestAPIVersionmetaDevUpboundIoV1Alpha1),
		Kind:       ptr.To(metav1alpha1.CompositionTestKindCompositionTest),
		Metadata:   &metav1.ObjectMeta{Name: ptr.To("import-observe-drift")},
		Spec:       &spec,
	}
}

func missingTest() metav1alpha1.CompositionTest {
	spec := commonSpec()
	spec.XrPath = ptr.To("tests/test-eks-import/xr-missing.yaml")

	assertResources := resourcesToItems[metav1alpha1.CompositionTestSpecAssertResourcesItem](
		compositeStatusImport(map[string]any{
			"active": true,
			"commit": false,
			"phase":  "Observing",
			"missing": []any{
				"ebsCSIDriverRole",
				"kubernetesCluster",
				"nodeGroupPublic",
				"vpcCniAddon",
				"ebsCsiAddon",
				"podIdentityAgentAddon",
				"ebsCSIDriverPodIdentityAssociation",
			},
			"error": "import.resources is set but required external names are missing; render blocked until all are provided",
		}),
	)
	spec.AssertResources = &assertResources

	return metav1alpha1.CompositionTest{
		APIVersion: ptr.To(metav1alpha1.CompositionTestAPIVersionmetaDevUpboundIoV1Alpha1),
		Kind:       ptr.To(metav1alpha1.CompositionTestKindCompositionTest),
		Metadata:   &metav1.ObjectMeta{Name: ptr.To("import-missing-blocks-render")},
		Spec:       &spec,
	}
}

func commitTest() metav1alpha1.CompositionTest {
	spec := commonSpec()
	spec.XrPath = ptr.To("tests/test-eks-import/xr-commit.yaml")

	assertResources := resourcesToItems[metav1alpha1.CompositionTestSpecAssertResourcesItem](
		commitAssertCluster(),
		compositeStatusImport(map[string]any{
			"active": true,
			"commit": true,
			"phase":  "Committing",
		}),
	)
	spec.AssertResources = &assertResources

	return metav1alpha1.CompositionTest{
		APIVersion: ptr.To(metav1alpha1.CompositionTestAPIVersionmetaDevUpboundIoV1Alpha1),
		Kind:       ptr.To(metav1alpha1.CompositionTestKindCompositionTest),
		Metadata:   &metav1.ObjectMeta{Name: ptr.To("import-commit-takes-management")},
		Spec:       &spec,
	}
}

func main() {
	items := []interface{}{
		observeTest(),
		missingTest(),
		commitTest(),
	}

	output := map[string]interface{}{
		"items": items,
	}
	out, err := yaml.Marshal(output)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error encoding YAML: %v\n", err)
		os.Exit(1)
	}
	fmt.Print(string(out))
}

func toItem[T any](resource interface{}) T {
	var item T
	if err := convertViaJSON(&item, resource); err != nil {
		panic(fmt.Sprintf("converting item: %v", err))
	}
	return item
}

func resourcesToItems[T any](resources ...interface{}) []T {
	items := make([]T, 0, len(resources))
	for _, res := range resources {
		items = append(items, toItem[T](res))
	}
	return items
}

func convertViaJSON(to, from any) error {
	bs, err := json.Marshal(from)
	if err != nil {
		return err
	}
	return json.Unmarshal(bs, to)
}
