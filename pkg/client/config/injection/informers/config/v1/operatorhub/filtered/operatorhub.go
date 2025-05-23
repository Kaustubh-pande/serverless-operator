// Code generated by injection-gen. DO NOT EDIT.

package filtered

import (
	context "context"

	filtered "github.com/openshift-knative/serverless-operator/pkg/client/config/injection/informers/factory/filtered"
	v1 "github.com/openshift/client-go/config/informers/externalversions/config/v1"
	controller "knative.dev/pkg/controller"
	injection "knative.dev/pkg/injection"
	logging "knative.dev/pkg/logging"
)

func init() {
	injection.Default.RegisterFilteredInformers(withInformer)
}

// Key is used for associating the Informer inside the context.Context.
type Key struct {
	Selector string
}

func withInformer(ctx context.Context) (context.Context, []controller.Informer) {
	untyped := ctx.Value(filtered.LabelKey{})
	if untyped == nil {
		logging.FromContext(ctx).Panic(
			"Unable to fetch labelkey from context.")
	}
	labelSelectors := untyped.([]string)
	infs := []controller.Informer{}
	for _, selector := range labelSelectors {
		f := filtered.Get(ctx, selector)
		inf := f.Config().V1().OperatorHubs()
		ctx = context.WithValue(ctx, Key{Selector: selector}, inf)
		infs = append(infs, inf.Informer())
	}
	return ctx, infs
}

// Get extracts the typed informer from the context.
func Get(ctx context.Context, selector string) v1.OperatorHubInformer {
	untyped := ctx.Value(Key{Selector: selector})
	if untyped == nil {
		logging.FromContext(ctx).Panicf(
			"Unable to fetch github.com/openshift/client-go/config/informers/externalversions/config/v1.OperatorHubInformer with selector %s from context.", selector)
	}
	return untyped.(v1.OperatorHubInformer)
}
