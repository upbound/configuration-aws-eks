package main

// Go port of functions/eks/main.k — the main EKS composition logic.
//
// This function reproduces the KCL render: it reads spec.parameters from the
// observed XR, builds all managed resources (IAM roles, EKS cluster, node group,
// addons, access entries, provider configs, etc.), applies the brownfield import
// lifecycle (management policies, external-name pinning, drift report via the
// ported importkit engine), and writes status.eks / status.import back to the XR.
//
// Composed resources are built as unstructured map[string]any (mirroring the KCL
// dicts) and wrapped in composed.Unstructured. The composition-resource-name is
// carried by the desired-resources MAP KEY; Crossplane adds the
// crossplane.io/composition-resource-name annotation from that key at render
// time, exactly like it does for function-kcl's krm.kcl.dev annotation.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	xpresource "github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/resource/composite"
	"github.com/crossplane/function-sdk-go/response"
)

// API versions for the managed resources (namespaced ".m." variants), matching
// the KCL models.io.upbound.awsm.* / models.io.crossplane.*m imports.
const (
	apiVersionEKS      = "eks.aws.m.upbound.io/v1beta1"
	apiVersionIAM      = "iam.aws.m.upbound.io/v1beta1"
	apiVersionEC2      = "ec2.aws.m.upbound.io/v1beta1"
	apiVersionK8sPC    = "kubernetes.m.crossplane.io/v1alpha1"
	apiVersionHelmPC   = "helm.m.crossplane.io/v1beta1"
	apiVersionEKSXR    = "aws.platform.upbound.io/v1alpha1"
	blockRenderErrText = "import.resources is set but required external names are missing; render blocked until all are provided"
)

// assume-role policy documents, copied verbatim from main.k (whitespace matters
// for byte-identical render vs. the KCL tests).
const controlplaneAssumeRolePolicy = `{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "eks.amazonaws.com"
                ]
            },
            "Action": [
                "sts:AssumeRole"
            ]
        }
    ]
  }
`

const nodegroupAssumeRolePolicy = `{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "ec2.amazonaws.com"
                ]
            },
            "Action": [
                "sts:AssumeRole"
            ]
        }
    ]
  }
`

const ebsCSIAssumeRolePolicy = `{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
`

// Function is your composition function.
type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer

	log logging.Logger
}

// RunFunction runs the Function.
func (f *Function) RunFunction(_ context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {
	f.log.Info("Running function", "tag", req.GetMeta().GetTag())

	rsp := response.To(req, response.DefaultTTL)

	// --- Read observed state -------------------------------------------------
	oxr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}
	observed, err := request.GetObservedComposedResources(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}
	xr := oxr.Resource

	// --- Parameters ----------------------------------------------------------
	id := getStr(xr, "spec.parameters.id", "")
	region := getStr(xr, "spec.parameters.region", "")
	version := getStr(xr, "spec.parameters.version", "1.34")
	authMode := getStr(xr, "spec.parameters.accessConfig.authenticationMode", "CONFIG_MAP")
	bootstrap := getBool(xr, "spec.parameters.accessConfig.bootstrapClusterCreatorAdminPermissions", true)
	instanceType := getStr(xr, "spec.parameters.nodes.instanceType", "t3.small")
	nodeCount := getInt(xr, "spec.parameters.nodes.count", 0)
	principalArn := getStr(xr, "spec.parameters.iam.principalArn", "")
	providerConfigName := getStr(xr, "spec.parameters.providerConfigName", "default")
	xrNamespace := getStr(xr, "metadata.namespace", "")

	// import config
	importResources := getMap(xr, "spec.parameters.import.resources")
	commit := getBool(xr, "spec.parameters.import.commit", false)
	importActive := len(importResources) > 0

	// network placement
	explicitSubnets := getStrArr(xr, "spec.parameters.network.subnetIds")
	explicitNodeSubnets := getStrArr(xr, "spec.parameters.network.nodeSubnetIds")
	if len(explicitNodeSubnets) == 0 {
		explicitNodeSubnets = explicitSubnets
	}
	useExplicitNetwork := len(explicitSubnets) > 0

	// management policies
	mgmtDefault := getStrArr(xr, "spec.parameters.managementPolicies")
	if len(mgmtDefault) == 0 {
		mgmtDefault = []string{"*"}
	}
	mgmt := managementPolicies(importActive, commit, mgmtDefault)

	// --- Build desired composed resources -----------------------------------
	dcds := map[xpresource.Name]*xpresource.DesiredComposed{}

	// helper closures capturing the shared config
	defaults := func() map[string]any {
		s := map[string]any{"managementPolicies": toAnySlice(mgmt)}
		if providerConfigName != "" {
			s["providerConfigRef"] = map[string]any{"kind": "ProviderConfig", "name": providerConfigName}
		}
		return s
	}
	// metaImp builds metadata with an optional external-name annotation (only when
	// importing and the key is present in import.resources). extra merges labels.
	metaImp := func(key string, extra map[string]any) map[string]any {
		md := map[string]any{}
		if importActive {
			if v, ok := importResources[key]; ok {
				md["annotations"] = map[string]any{"crossplane.io/external-name": v}
			}
		}
		for k, v := range extra {
			md[k] = v
		}
		return md
	}

	// 1. controlplane IAM Role (always)
	dcds["controlplaneRole"] = desired(map[string]any{
		"apiVersion": apiVersionIAM,
		"kind":       "Role",
		"metadata":   metaImp("controlplaneRole", map[string]any{"labels": map[string]any{"role": "controlplane"}}),
		"spec": merge(defaults(), map[string]any{
			"forProvider": map[string]any{
				"forceDetachPolicies": true,
				"managedPolicyArns":   []any{"arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"},
				"assumeRolePolicy":    controlplaneAssumeRolePolicy,
			},
		}),
	})

	// 2. EKS Cluster (always)
	clusterVPCConfig := map[string]any{"endpointPrivateAccess": true}
	if useExplicitNetwork {
		clusterVPCConfig["subnetIds"] = toAnySlice(explicitSubnets)
	}
	if !useExplicitNetwork && !importActive {
		clusterVPCConfig["subnetIdSelector"] = map[string]any{
			"matchLabels": map[string]any{
				"networks.aws.platform.upbound.io/network-id": id,
				"access": "public",
			},
		}
	}
	dcds["kubernetesCluster"] = desired(map[string]any{
		"apiVersion": apiVersionEKS,
		"kind":       "Cluster",
		"metadata":   metaImp("kubernetesCluster", nil),
		"spec": merge(defaults(), map[string]any{
			"forProvider": map[string]any{
				"region":  region,
				"version": version,
				"accessConfig": map[string]any{
					"authenticationMode":                      authMode,
					"bootstrapClusterCreatorAdminPermissions": bootstrap,
				},
				"roleArnSelector": map[string]any{
					"matchControllerRef": true,
					"matchLabels":        map[string]any{"role": "controlplane"},
				},
				"vpcConfig": clusterVPCConfig,
			},
		}),
	})

	// 3. conditional EC2 SecurityGroup import (when the cluster reports its
	//    clusterSecurityGroupId).
	clusterSGID := getPathString(observed, "kubernetesCluster", "status", "atProvider", "vpcConfig", "clusterSecurityGroupId")
	if clusterSGID != "" {
		dcds["clusterSecurityGroupImport"] = desired(map[string]any{
			"apiVersion": apiVersionEC2,
			"kind":       "SecurityGroup",
			"metadata": map[string]any{
				"annotations": map[string]any{"crossplane.io/external-name": clusterSGID},
			},
			"spec": merge(defaults(), map[string]any{
				"forProvider": map[string]any{
					"region": region,
					"tags":   map[string]any{"eks.aws.platform.upbound.io/discovery": id},
				},
			}),
		})
	}

	// 4. ClusterAuth (gated). Always ["*"] management policies (token generator,
	//    no importable external state).
	if importActive || ready(observed, "kubernetesCluster") || exists(observed, "kubernetesClusterAuth") {
		caSpec := merge(defaults(), map[string]any{
			"managementPolicies": toAnySlice(mgmtDefault),
			"forProvider": map[string]any{
				"region":              region,
				"clusterNameSelector": map[string]any{"matchControllerRef": true},
				// Schema default from the ClusterAuth model (refreshPeriod?: str = "10m0s").
				// KCL applied this automatically on model instantiation; the Go function
				// builds raw maps, so we set the provider default explicitly for parity.
				"refreshPeriod": "10m0s",
			},
			"writeConnectionSecretToRef": map[string]any{"name": id + "-ekscluster"},
		})
		dcds["kubernetesClusterAuth"] = desired(map[string]any{
			"apiVersion": apiVersionEKS,
			"kind":       "ClusterAuth",
			"metadata":   map[string]any{},
			"spec":       caSpec,
		})
	}

	// 5. nodegroup IAM Role (always)
	dcds["nodegroupRole"] = desired(map[string]any{
		"apiVersion": apiVersionIAM,
		"kind":       "Role",
		"metadata":   metaImp("nodegroupRole", map[string]any{"labels": map[string]any{"role": "nodegroup"}}),
		"spec": merge(defaults(), map[string]any{
			"forProvider": map[string]any{
				"forceDetachPolicies": true,
				"managedPolicyArns": []any{
					"arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
					"arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
					"arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
					"arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
				},
				"assumeRolePolicy": nodegroupAssumeRolePolicy,
			},
		}),
	})

	// 6. NodeGroup (gated)
	if importActive || ready(observed, "vpc-cni-addon") || exists(observed, "nodeGroupPublic") {
		ngForProvider := map[string]any{
			"region":              region,
			"clusterNameSelector": map[string]any{"matchControllerRef": true},
			"nodeRoleArnSelector": map[string]any{
				"matchControllerRef": true,
				"matchLabels":        map[string]any{"role": "nodegroup"},
			},
			"scalingConfig": map[string]any{"maxSize": 100, "minSize": 1},
			"instanceTypes": []any{instanceType},
		}
		if useExplicitNetwork {
			ngForProvider["subnetIds"] = toAnySlice(explicitNodeSubnets)
		}
		if !useExplicitNetwork && !importActive {
			ngForProvider["subnetIdSelector"] = map[string]any{
				"matchLabels": map[string]any{
					"networks.aws.platform.upbound.io/network-id": id,
					"access": "public",
				},
			}
		}
		dcds["nodeGroupPublic"] = desired(map[string]any{
			"apiVersion": apiVersionEKS,
			"kind":       "NodeGroup",
			"metadata":   metaImp("nodeGroupPublic", nil),
			"spec": merge(defaults(), map[string]any{
				"initProvider": map[string]any{
					"scalingConfig": map[string]any{"desiredSize": nodeCount},
				},
				"forProvider": ngForProvider,
			}),
		})
	}

	// 7. AccessEntry + AccessPolicyAssociation (only when principalArn set).
	//    Resource names are sha256 hex of a seed so they recreate when the ARN
	//    changes.
	if principalArn != "" {
		aeName := sha256Hex("accessEntry-" + principalArn)
		apaName := sha256Hex("accessPolicyAssociation-" + principalArn)
		dcds[xpresource.Name(aeName)] = desired(map[string]any{
			"apiVersion": apiVersionEKS,
			"kind":       "AccessEntry",
			"metadata":   metaImp("accessEntry", nil),
			"spec": merge(defaults(), map[string]any{
				"forProvider": map[string]any{
					"region":              region,
					"clusterNameSelector": map[string]any{"matchControllerRef": true},
					"type":                "STANDARD",
					"principalArn":        principalArn,
				},
			}),
		})
		dcds[xpresource.Name(apaName)] = desired(map[string]any{
			"apiVersion": apiVersionEKS,
			"kind":       "AccessPolicyAssociation",
			"metadata":   metaImp("accessPolicyAssociation", nil),
			"spec": merge(defaults(), map[string]any{
				"forProvider": map[string]any{
					"region":               region,
					"accessScope":          map[string]any{"type": "cluster"},
					"clusterNameSelector":  map[string]any{"matchControllerRef": true},
					"policyArn":            "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy",
					"principalArnSelector": map[string]any{"matchControllerRef": true},
				},
			}),
		})
	}

	// 8. vpc-cni Addon (gated)
	if importActive || ready(observed, "kubernetesClusterAuth") || exists(observed, "vpc-cni-addon") {
		dcds["vpc-cni-addon"] = desired(map[string]any{
			"apiVersion": apiVersionEKS,
			"kind":       "Addon",
			"metadata":   metaImp("vpcCniAddon", nil),
			"spec": merge(defaults(), map[string]any{
				"forProvider": map[string]any{
					"region":              region,
					"addonName":           "vpc-cni",
					"clusterNameSelector": map[string]any{"matchControllerRef": true},
					"configurationValues": `{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}`,
				},
			}),
		})
	}

	// 9. ebs-csi-driver IAM Role (always)
	dcds["ebsCSIDriverRole"] = desired(map[string]any{
		"apiVersion": apiVersionIAM,
		"kind":       "Role",
		"metadata":   metaImp("ebsCSIDriverRole", map[string]any{"labels": map[string]any{"role": "ebs-csi-driver"}}),
		"spec": merge(defaults(), map[string]any{
			"forProvider": map[string]any{
				"forceDetachPolicies": true,
				"managedPolicyArns":   []any{"arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"},
				"assumeRolePolicy":    ebsCSIAssumeRolePolicy,
			},
		}),
	})

	// 10. ebsCSIDriver PodIdentityAssociation (always)
	dcds["ebsCSIDriverPodIdentityAssociation"] = desired(map[string]any{
		"apiVersion": apiVersionEKS,
		"kind":       "PodIdentityAssociation",
		"metadata":   metaImp("ebsCSIDriverPodIdentityAssociation", nil),
		"spec": merge(defaults(), map[string]any{
			"forProvider": map[string]any{
				"region":              region,
				"clusterNameSelector": map[string]any{"matchControllerRef": true},
				"namespace":           "kube-system",
				"serviceAccount":      "ebs-csi-controller-sa",
				"roleArnSelector": map[string]any{
					"matchControllerRef": true,
					"matchLabels":        map[string]any{"role": "ebs-csi-driver"},
				},
			},
		}),
	})

	// 11. aws-ebs-csi-driver Addon (gated)
	if importActive ||
		(ready(observed, "ebsCSIDriverPodIdentityAssociation") && ready(observed, "nodeGroupPublic")) ||
		exists(observed, "aws-ebs-csi-driver-addon") {
		dcds["aws-ebs-csi-driver-addon"] = desired(map[string]any{
			"apiVersion": apiVersionEKS,
			"kind":       "Addon",
			"metadata":   metaImp("ebsCsiAddon", nil),
			"spec": merge(defaults(), map[string]any{
				"forProvider": map[string]any{
					"region":              region,
					"addonName":           "aws-ebs-csi-driver",
					"clusterNameSelector": map[string]any{"matchControllerRef": true},
					"configurationValues": `{"defaultStorageClass": {"enabled": true}}`,
				},
			}),
		})
	}

	// 12. eks-pod-identity-agent Addon (gated). NOTE: exists() checks the key
	//     "eks-pod-identity-agent" (not "...-addon"), replicating main.k exactly.
	if importActive || ready(observed, "nodeGroupPublic") || exists(observed, "eks-pod-identity-agent") {
		dcds["eks-pod-identity-agent-addon"] = desired(map[string]any{
			"apiVersion": apiVersionEKS,
			"kind":       "Addon",
			"metadata":   metaImp("podIdentityAgentAddon", nil),
			"spec": merge(defaults(), map[string]any{
				"forProvider": map[string]any{
					"region":              region,
					"addonName":           "eks-pod-identity-agent",
					"clusterNameSelector": map[string]any{"matchControllerRef": true},
				},
			}),
		})
	}

	// 13. kubernetes ProviderConfig (always, marked ready)
	pcK8s := desired(map[string]any{
		"apiVersion": apiVersionK8sPC,
		"kind":       "ProviderConfig",
		"metadata": map[string]any{
			"name":         id,
			"generateName": id + "-",
		},
		"spec": map[string]any{
			"credentials": map[string]any{
				"secretRef": map[string]any{
					"name":      id + "-ekscluster",
					"namespace": xrNamespace,
					"key":       "kubeconfig",
				},
				"source": "Secret",
			},
		},
	})
	pcK8s.Ready = xpresource.ReadyTrue
	dcds["providerConfig-kubernetes"] = pcK8s

	// 14. helm ProviderConfig (always, marked ready)
	pcHelm := desired(map[string]any{
		"apiVersion": apiVersionHelmPC,
		"kind":       "ProviderConfig",
		"metadata": map[string]any{
			"name":         id,
			"generateName": id + "-",
		},
		"spec": map[string]any{
			"credentials": map[string]any{
				"secretRef": map[string]any{
					"name":      id + "-ekscluster",
					"namespace": xrNamespace,
					"key":       "kubeconfig",
				},
				"source": "Secret",
			},
		},
	})
	pcHelm.Ready = xpresource.ReadyTrue
	dcds["providerConfig-helm"] = pcHelm

	// --- Import report (importkit) ------------------------------------------
	requiredKeys := []string{
		"controlplaneRole", "nodegroupRole", "ebsCSIDriverRole", "kubernetesCluster",
		"nodeGroupPublic", "vpcCniAddon", "ebsCsiAddon", "podIdentityAgentAddon",
		"ebsCSIDriverPodIdentityAssociation",
	}
	if principalArn != "" {
		requiredKeys = append(requiredKeys, "accessEntry", "accessPolicyAssociation")
	}

	registry := map[string]string{
		"kubernetesCluster":                  "kubernetesCluster",
		"nodeGroupPublic":                    "nodeGroupPublic",
		"controlplaneRole":                   "controlplaneRole",
		"nodegroupRole":                      "nodegroupRole",
		"ebsCSIDriverRole":                   "ebsCSIDriverRole",
		"vpcCniAddon":                        "vpc-cni-addon",
		"ebsCsiAddon":                        "aws-ebs-csi-driver-addon",
		"podIdentityAgentAddon":              "eks-pod-identity-agent-addon",
		"ebsCSIDriverPodIdentityAssociation": "ebsCSIDriverPodIdentityAssociation",
	}
	if principalArn != "" {
		registry["accessEntry"] = sha256Hex("accessEntry-" + principalArn)
		registry["accessPolicyAssociation"] = sha256Hex("accessPolicyAssociation-" + principalArn)
	}

	reconcilable := []string{"version", "authenticationMode", "instanceTypes", "desiredSize", "subnetIds"}

	report := Report{Missing: []string{}, BlockRender: false, Resources: map[string]Entry{}}
	if importActive {
		report = buildReport(ReportConfig{
			OCDS:            ocdsForImportkit(observed),
			ImportResources: importResources,
			Registry:        registry,
			Reconcilable:    reconcilable,
			RequiredKeys:    requiredKeys,
		})
	}

	// --- Assemble status.eks / status.import --------------------------------
	dxr, err := request.GetDesiredCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	// status.eks derivations from the observed cluster / node group.
	var clusterName, clusterArn, nodeGroupArn any
	oidcIssuerURL := ""
	ngInstanceType := ""
	if oc, ok := observed["kubernetesCluster"]; ok {
		obj := oc.Resource.Object
		clusterName = getPathAny(obj, "metadata", "name")
		at := asMapAny(getPathAny(obj, "status", "atProvider"))
		clusterArn = at["arn"]
		oidcIssuerURL = deriveOIDCIssuer(at)
	}
	if oc, ok := observed["nodeGroupPublic"]; ok {
		at := asMapAny(getPathAny(oc.Resource.Object, "status", "atProvider"))
		nodeGroupArn = at["arn"]
		if its, ok := at["instanceTypes"].([]any); ok && len(its) > 0 {
			if s, ok := its[0].(string); ok {
				ngInstanceType = s
			}
		}
	}
	eksStatus := map[string]any{
		"clusterName":   clusterName,
		"clusterArn":    clusterArn,
		"oidcIssuerUrl": oidcIssuerURL,
		"nodeGroupArn":  nodeGroupArn,
		"nodeGroup":     map[string]any{"instanceType": ngInstanceType},
	}
	if err := dxr.Resource.SetValue("status.eks", eksStatus); err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	if importActive {
		phase := "Observing"
		if commit {
			phase = "Committing"
		}
		imp := map[string]any{
			"active":  true,
			"commit":  commit,
			"phase":   phase,
			"missing": toAnySlice(report.Missing),
		}
		if report.BlockRender {
			imp["error"] = blockRenderErrText
		} else {
			imp["resources"] = entriesToAny(report.Resources)
			imp["driftCount"] = report.DriftCount
			imp["sideEffectCount"] = report.SideEffectCount
		}
		if err := dxr.Resource.SetValue("status.import", imp); err != nil {
			response.Fatal(rsp, err)
			return rsp, nil
		}
	}

	// --- Emit ----------------------------------------------------------------
	// When render is blocked, emit ONLY the XR (no composed resources); mirror
	// KCL `items = [_dxr] if blockRender else _items`.
	if !report.BlockRender {
		// CompositeConnectionDetails: surface the ClusterAuth kubeconfig on the XR.
		if oc, ok := observed["kubernetesClusterAuth"]; ok {
			if kc, ok := oc.ConnectionDetails["kubeconfig"]; ok {
				dxr.ConnectionDetails["kubeconfig"] = kc
			}
		}
		if err := response.SetDesiredComposedResources(rsp, dcds); err != nil {
			response.Fatal(rsp, err)
			return rsp, nil
		}
	}

	if err := response.SetDesiredCompositeResource(rsp, dxr); err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	response.ConditionTrue(rsp, "FunctionSuccess", "Success").
		TargetCompositeAndClaim()

	return rsp, nil
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// desired wraps an unstructured object map in a DesiredComposed.
func desired(obj map[string]any) *xpresource.DesiredComposed {
	cd := composed.New()
	cd.SetUnstructuredContent(obj)
	return &xpresource.DesiredComposed{Resource: cd}
}

// merge shallow-merges src into dst (dst wins on conflicts is NOT desired here;
// src overrides dst), returning dst. Mirrors KCL dict union `a | b`.
func merge(dst, src map[string]any) map[string]any {
	for k, v := range src {
		dst[k] = v
	}
	return dst
}

func toAnySlice(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// exists reports whether a composition resource is present in observed state.
func exists(ocds map[xpresource.Name]xpresource.ObservedComposed, key string) bool {
	_, ok := ocds[xpresource.Name(key)]
	return ok
}

// ready mirrors KCL `ready`: all conditions True and status.atProvider present.
func ready(ocds map[xpresource.Name]xpresource.ObservedComposed, key string) bool {
	oc, ok := ocds[xpresource.Name(key)]
	if !ok {
		return false
	}
	st, ok := oc.Resource.Object["status"].(map[string]any)
	if !ok {
		return false
	}
	conds, ok := st["conditions"].([]any)
	if !ok || len(conds) == 0 {
		return false
	}
	for _, c := range conds {
		cm, ok := c.(map[string]any)
		if !ok {
			return false
		}
		if s, _ := cm["status"].(string); s != "True" {
			return false
		}
	}
	_, hasAt := st["atProvider"]
	return hasAt
}

// ocdsForImportkit re-shapes the SDK observed resources into the KCL _ocds shape
// expected by importkit: {crName: {"Resource": <obj>, "ConnectionDetails": {...}}}.
func ocdsForImportkit(ocds map[xpresource.Name]xpresource.ObservedComposed) map[string]any {
	out := map[string]any{}
	for name, oc := range ocds {
		cd := map[string]any{}
		for k, v := range oc.ConnectionDetails {
			cd[k] = string(v)
		}
		out[string(name)] = map[string]any{
			"Resource":          oc.Resource.Object,
			"ConnectionDetails": cd,
		}
	}
	return out
}

// entriesToAny converts the typed report entries to unstructured maps (via JSON,
// honoring Change's custom MarshalJSON) for status output.
func entriesToAny(entries map[string]Entry) map[string]any {
	out := map[string]any{}
	for k, e := range entries {
		b, err := json.Marshal(e)
		if err != nil {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(b, &m); err != nil {
			continue
		}
		out[k] = m
	}
	return out
}

// deriveOIDCIssuer mirrors main.k: atProvider.identity[0].oidc[0].issuer.
func deriveOIDCIssuer(at map[string]any) string {
	idList, ok := at["identity"].([]any)
	if !ok || len(idList) == 0 {
		return ""
	}
	id0, ok := idList[0].(map[string]any)
	if !ok {
		return ""
	}
	oidcList, ok := id0["oidc"].([]any)
	if !ok || len(oidcList) == 0 {
		return ""
	}
	o0, ok := oidcList[0].(map[string]any)
	if !ok {
		return ""
	}
	if s, ok := o0["issuer"].(string); ok {
		return s
	}
	return ""
}

// --- unstructured getters ---------------------------------------------------

func getStr(xr *composite.Unstructured, path, def string) string {
	if v, err := xr.GetString(path); err == nil {
		return v
	}
	return def
}

func getBool(xr *composite.Unstructured, path string, def bool) bool {
	if v, err := xr.GetBool(path); err == nil {
		return v
	}
	return def
}

func getInt(xr *composite.Unstructured, path string, def int) int {
	if v, err := xr.GetInteger(path); err == nil {
		return int(v)
	}
	return def
}

func getStrArr(xr *composite.Unstructured, path string) []string {
	if v, err := xr.GetStringArray(path); err == nil {
		return v
	}
	return nil
}

// getMap reads a string->string map (import.resources) as map[string]any.
func getMap(xr *composite.Unstructured, path string) map[string]any {
	v, err := xr.GetValue(path)
	if err != nil {
		return map[string]any{}
	}
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

func asMapAny(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

// getPathAny walks nested map[string]any by keys, returning nil if absent.
func getPathAny(obj map[string]any, keys ...string) any {
	var cur any = obj
	for _, k := range keys {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur, ok = m[k]
		if !ok {
			return nil
		}
	}
	return cur
}

// getPathString walks the observed resource map to a string leaf.
func getPathString(ocds map[xpresource.Name]xpresource.ObservedComposed, name string, keys ...string) string {
	oc, ok := ocds[xpresource.Name(name)]
	if !ok {
		return ""
	}
	v := getPathAny(oc.Resource.Object, keys...)
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}
