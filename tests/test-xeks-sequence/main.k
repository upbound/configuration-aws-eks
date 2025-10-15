"""
    This test suite validates the sequential creation and readiness of AWS EKS resources.
    Each test step incrementally adds resources and verifies their "Ready" condition
    before proceeding to the next.

    The resource creation flow is validated in the following order:

    Sequence 0 (created immediately):
    - kubernetesCluster
    - IAM roles (controlplane, nodegroup, ebs-csi-driver)
    - ebsCSIDriverPodIdentityAssociation (waits for role via selector)
    - providerConfigs

    Sequence 1 (after kubernetesCluster ready):
    - kubernetesClusterAuth

    Sequence 2 (after kubernetesClusterAuth ready):
    - vpc-cni-addon

    Sequence 3 (after vpc-cni-addon ready):
    - nodeGroupPublic

    Sequence 4 (after ebsCSIDriverPodIdentityAssociation AND nodeGroupPublic ready):
    - aws-ebs-csi-driver-addon
    - eks-pod-identity-agent-addon

    Each test (_test1 to _test5) adds new resources and ensures the previously created
    ones have reached a "Ready" status, enforcing the correct creation and dependency order.
"""

import models.io.upbound.aws.eks.v1beta1 as eksv1beta1
import models.io.upbound.aws.eks.v1beta2 as eksv1beta2
import models.io.upbound.aws.iam.v1beta1 as iamv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import resources
import conditions

_spec = metav1alpha1.CompositionTest {
    spec = {
        compositionPath: "apis/composition.yaml"
        xrPath: "examples/eks-xr.yaml"
        xrdPath: "apis/definition.yaml"
        timeoutSeconds: 60
        validate: False
    }
}

_test1 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0"
    **_spec
    spec.assertResources: [
        resources._xr
        resources._kubernetesCluster
        resources._roleControlPlane
        resources._roleNodeGroup
        resources._ebsCSIDriverRole
        resources._ebsCSIDriverPodIdentityAssociation
        resources._providerConfigHelm
        resources._providerConfigKubernetes
    ]
}

_test2 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0-cluster-ready"
    **_spec
    spec.observedResources: [
        eksv1beta2.Cluster {
            **resources._kubernetesCluster
            status: {
                atProvider:{
                    id: "test-kubernetes-cluster"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test1.spec.assertResources + [
        _kubernetesClusterAuth
    ]
}

_test3 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0-cluster-auth-ready"
    **_spec
    spec.observedResources: _test2.spec.observedResources + [
        eksv1beta1.ClusterAuth {
            **resources._kubernetesClusterAuth
            status: {
                atProvider: {
                    lastRefreshTime: "12345"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test2.spec.assertResources + [
        resources._vpcCniAddon
    ]
}

_test4 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0-vpc-cni-addon-ready"
    **_spec
    spec.observedResources: _test3.spec.observedResources + [
        eksv1beta1.Addon {
            **resources._vpcCniAddon
            status: {
                atProvider:{
                    id: "test-vpc-cni-addon"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test3.spec.assertResources + [
        resources._nodeGroupPublic
    ]
}

_test5 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0-pod-identity-and-nodegroup-ready"
    **_spec
    spec.observedResources: _test4.spec.observedResources + [
        iamv1beta1.Role {
            **resources._ebsCSIDriverRole
            status: {
                atProvider:{
                    arn: "arn:aws:iam::123456789012:role/test-ebs-csi-driver-role"
                }
                conditions: conditions._readyConditions
            }
        }
        eksv1beta1.PodIdentityAssociation {
            **resources._ebsCSIDriverPodIdentityAssociation
            status: {
                atProvider:{
                    associationId: "test-pod-identity-association"
                }
                conditions: conditions._readyConditions
            }
        }
        eksv1beta2.NodeGroup {
            **resources._nodeGroupPublic
            status: {
                atProvider:{
                    id: "test-nodegroup-public"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test4.spec.assertResources + [
        resources._awsEbsCsiDriverAddon
        resources._eksPodIdentityAgentAddon
    ]
}

items = [_test1, _test2, _test3, _test4, _test5]
