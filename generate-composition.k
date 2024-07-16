import file
import yaml

composition = yaml.decode(file.read("apis/composition-kcl.yaml.template"))

_kcl_step = composition.spec.pipeline[0]

kcl_file = _kcl_step.input.spec.source

_kcl_step.input.spec.source = file.read(kcl_file)

composition_yaml = yaml.encode(composition)

file.write("apis/composition-kcl.yaml", composition_yaml)
