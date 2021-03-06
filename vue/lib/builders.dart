import 'dart:async';

import 'package:analyzer/analyzer.dart';
import 'package:build/build.dart';
import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' show CssPrinter;
import 'package:html/parser.dart' as html;
import 'package:scopify/scopify.dart';
import 'package:source_span/source_span.dart' show SourceFile;
import 'package:source_maps/refactor.dart';
import 'package:uuid/uuid.dart';


class AnnotationArgs {
  final List<Expression> positional;
  final Map<String, Expression> named;

  AnnotationArgs(this.positional, this.named);
}


class Prop {
  final String name;
  final TypeName type;
  final Expression initializer;

  Prop(this.name, this.type, this.initializer);
}


class Data {
  final String name;
  final Expression initializer;

  Data(this.name, this.initializer);
}


class Computed {
  final String name;
  bool hasSetter;

  Computed(this.name);
}


class Method {
  final String name;
  final List<FormalParameter> params;

  Method(this.name, this.params);
}


class Watcher {
  final String funcName, propName;
  final int nparams;
  final bool deep;

  Watcher(this.funcName, this.propName, this.nparams, this.deep);
}


class VueClassInfo {
  List<Prop> props = [];
  List<Data> data = [];
  Map<String, Computed> computed = {};
  List<Method> methods = [];
  List<Watcher> watchers = [];

  VueClassInfo();
}

class VueImportedComponent {
  String prefix, name;

  VueImportedComponent(this.prefix, this.name);
  String get prefixed => prefix != null ? '$prefix.$name' : name;
}


class VuedartBuildContext {
  final BuildStep buildStep;

  SourceFile source;
  AssetId inputId;
  TextEditTransaction rewriter;
  CompilationUnit unit;

  VuedartBuildContext(this.buildStep): inputId = buildStep.inputId;

  void error(AstNode node, String error) {
    var span = source.span(node.offset, node.end);
    log.severe(span.message(error));
  }

  Annotation getAnn(AnnotatedNode node, List<String> annotations) {
    var it = node.metadata.where((ann) => annotations.contains(ann.name.name));
    return it.isNotEmpty ? it.first : null;
  }

  Annotation getVueAnn(ClassDeclaration cls) =>
    getAnn(cls, ['VueApp', 'VueComponent', 'VueMixin']);
  bool containsVueAnn(ClassDeclaration cls) => getVueAnn(cls) != null;

  AnnotationArgs getAnnArgs(Annotation ann) {
    var positional = <Expression>[];
    var named = <String, Expression>{};

    for (var arg in ann.arguments.arguments) {
      if (arg is NamedExpression) {
        named[arg.name.label.name] = arg.expression;
      } else {
        positional.add(arg);
      }
    }

    return new AnnotationArgs(positional, named);
  }

  String computedGet(String name) => 'vuedart_INTERNAL_cg_$name';
  String computedSet(String name) => 'vuedart_INTERNAL_cs_$name';
  String method(String name) => 'vuedart_INTERAL_m_$name';

  String methodParams(List<FormalParameter> params) =>
    params.map((p) => p.identifier.name).join(', ');

  String sourceOrNull(AstNode node) => node?.toSource() ?? 'null';

  String codegenPropType(Prop prop) {
    switch (prop.type.name.name) {
    case 'num':
    case 'int':
    case 'double':
      return '#number';
    case 'String':
      return '#string';
    case 'bool':
      return '#bool';
    default:
      return 'null';
    }
  }

  String codegenProp(Prop prop) =>
    ''' '${prop.name}': new VueProp(
      ${codegenPropType(prop)},
      (_) => _ is ${prop.type.toSource()},
      ${sourceOrNull(prop.initializer)}
    ), ''';

  String codegenData(Data data) =>
    ''' '${data.name}': ${sourceOrNull(data.initializer)}, ''';

  String codegenComputed(Computed computed) =>
    '''
  '${computed.name}': new VueComputed(
    (_) => vueGetObj(_).${computedGet(computed.name)}(),
    ${computed.hasSetter
      ? '(_,__) => vueGetObj(_).${computedSet(computed.name)}(__)'
      : 'null'}),
    ''';

  String codegenWatch(Watcher watcher) =>
    '''
  '${watcher.propName}': new VueWatcher(
    (_, _nv, _ov) => vueGetObj(_).${watcher.funcName}(
        ${['_nv', '_ov'].getRange(0, watcher.nparams).join(', ')}
      ),
    ${watcher.deep},
  ),
    ''';

  String codegenMethod(Method meth) =>
    '''
    '${meth.name}': (_, ${methodParams(meth.params)}) =>
              vueGetObj(_).${method(meth.name)}(${methodParams(meth.params)}),
    ''';

  String codegenString(String str) => 'r"""${str.replaceAll('"""', '\\"""')}"""';

  String codegenConstructorList(ListLiteral items) =>
    '[${items.map((item) => '${item.name}.constructor').join(', ')}]';

  String codegenRegister(VueImportedComponent icls) =>
    'VueComponentBase.register(#${icls.name}, ${icls.prefixed}.constructor);';

  List<ClassDeclaration> getVueClasses(LibraryElement lib) =>
    lib.units.expand((unit) => unit.unit.declarations)
             .where((d) => d is ClassDeclaration && containsVueAnn(d))
             .map((d) => d as ClassDeclaration).toList();

  List<VueImportedComponent> getVueComponents(List<ClassDeclaration> classes,
                                              [String prefix]) =>
    classes.where((cls) => getVueAnn(cls)?.name?.name == 'VueComponent')
           .map((cls) => new VueImportedComponent(prefix, cls.name.name));

  void processField(FieldDeclaration member, VueClassInfo info) {
    var fields = member.fields;

    if (fields.variables.length == 1 &&
        fields.variables[0].name.name == 'constructor') {
      rewriter.edit(member.offset, member.end+1, '');
    }

    var ann = getAnn(member, ['prop', 'data', 'ref']);
    if (ann == null) return;

    var type = fields.type;
    var typestring = type.toSource();

    // Remove the type portion of the declaration, since it will be added for each element.
    rewriter.edit(type.offset, type.end+1, '');

    for (var decl in fields.variables) {
      var name = decl.name.name;

      if (ann.name.name == 'ref') {
        rewriter.edit(decl.offset, decl.end+1, '''
$typestring get $name => \$ref('$name');
        ''');
      } else {
        rewriter.edit(decl.offset, decl.end+1, '''
$typestring get $name => vuedart_get('$name');
void set $name($typestring value) => vuedart_set('$name', value);
        ''');

        switch (ann.name.name) {
        case 'prop':
          info.props.add(new Prop(name, type, decl.initializer));
          break;
        case 'data':
          info.data.add(new Data(name, decl.initializer));
          break;
        }
      }
    }
  }

  void processMethod(MethodDeclaration member, VueClassInfo info) {
    var ann = getAnn(member, ['computed', 'method', 'watch']);
    if (ann == null) return;

    if ((ann.name.name == 'computed' && !member.isGetter && !member.isSetter) ||
        (ann.name.name != 'computed' && (member.isGetter || member.isSetter))) {
      error(member, 'annotation on invalid member');
      return;
    }

    var name = member.name.name;
    var typestring = member.returnType?.name?.name ?? '';

    if (member.isGetter) {
      rewriter.edit(member.offset, member.end, '''
$typestring ${computedGet(name)}() ${member.body.toSource()}
$typestring get $name => vuedart_get('$name');
      ''');
      info.computed[name] = new Computed(name);
    } else if (member.isSetter) {
      if (!info.computed.containsKey(name)) {
        error(member, 'computed setters must follow getters');
        return;
      }

      info.computed[name].hasSetter = true;
      rewriter.edit(member.offset, member.end, '''
$typestring ${computedSet(name)}${member.parameters.toSource()}
  ${member.body.toSource()}
$typestring set $name($typestring value) => vuedart_set('$name', value);
      ''');
    } else if (ann.name.name == 'watch') {
      if (member.parameters.parameters.length > 2) {
        error(member.parameters, 'watchers can only take up to 2 parameters');
        return;
      }

      var args = getAnnArgs(ann);
      var propName = (args.positional[0] as StringLiteral).stringValue;
      var deep = false;

      if (args.named.containsKey('deep') && args.named['deep'] is BooleanLiteral) {
        deep = (args.named['deep'] as BooleanLiteral).value;
      }

      rewriter.edit(member.offset, member.end, '''
$typestring $name${member.parameters.toSource()}
  ${member.body.toSource()}
        ''');
      info.watchers.add(new Watcher(name, propName, member.parameters.parameters.length,
                                    deep));
    } else if (ann.name.name == 'method') {
      rewriter.edit(member.offset, member.end, '''
$typestring ${method(name)}${member.parameters.toSource()}
  ${member.body.toSource()}
$typestring $name${member.parameters.toSource()} =>
  vuedart_get('$name')(${methodParams(member.parameters.parameters)});
        ''');
      info.methods.add(new Method(name, member.parameters.parameters));
    }
  }

  Future readTemplate(Annotation ann, String path) async {
    var relhtmlpath = path.substring(2);
    var htmlasset;

    if (relhtmlpath == '') {
      htmlasset = inputId.changeExtension('.html');
    } else {
      htmlasset = new AssetId(inputId.package,
                              inputId.path + '/../' + relhtmlpath);
    }

    if (await buildStep.canRead(htmlasset)) {
      var doc = html.parse(await buildStep.readAsString(htmlasset));

      if (doc.querySelector('template') == null) {
        error(ann, 'template file does not have a template');
        return new Future.value();
      }

      var templates = doc.querySelectorAll('template[vuedart]');
      if (templates.isEmpty) {
        error(ann, 'no VueDart templates; did you forget the vuedart attribute?');
        return new Future.value();
      } else if (templates.length != 1) {
        error(ann, 'only one vuedart template is allowed');
        return new Future.value();
      }

      var template = templates[0];
      var uuid = new Uuid().v4();
      scopify(html: [template], css: [], uuid: uuid);

      var styleInject = '';
      var styles = doc.querySelectorAll('style[scoped]');
      if (styles.isNotEmpty) {
        var parsedStyles = [];
        var printer = new CssPrinter();

        for (var style in styles) {
          var errors = [];
          var parsed = css.parse(style.innerHtml, errors: errors);

          if (errors.isNotEmpty) {
            error(ann, 'errors parsing CSS style');
            for (var error in errors) {
              log.severe(error.toString());
            }
            continue;
          }

          scopify(html: [], css: [parsed], uuid: uuid,
                  bleeds: style.attributes.containsKey('bleeds'));
          parsed.visit(printer);
        }

        styleInject = printer.toString();
      }

      return new Future.value([template.innerHtml, styleInject]);
    } else {
      error(ann, 'template file $relhtmlpath does not exist');
      return new Future.value();
    }
  }

  Future processClass(ClassDeclaration cls) async {
    var ann = getVueAnn(cls);
    var args = getAnnArgs(ann);
    var info = new VueClassInfo();

    for (var member in cls.members) {
      if (member is FieldDeclaration) {
        processField(member, info);
      } else if (member is MethodDeclaration) {
        processMethod(member, info);
      }
    }

    var components = (args.named['components'] as ListLiteral)?.elements ?? [];
    var opts = '''
  data: {${info.data.map(codegenData).join('\n')}},
  computed: {${info.computed.values.map(codegenComputed).join('\n')}},
  watchers: {${info.watchers.map(codegenWatch).join('\n')}},
  methods: {${info.methods.map(codegenMethod).join('\n')}},
  components: ${codegenConstructorList(components)},
    ''';
    var code;

    if (ann.name.name == 'VueComponent' || ann.name.name == 'VueMixin') {
      var name = cls.name.name, creator;

      if (ann.name.name == 'VueComponent') {
        creator = '(context) => new $name(context)';
      }

      var template = args.named['template'] as StringLiteral;
      var templateString = '';
      var styleInject = '';

      if (template == null) {
        templateString = 'null';
      } else {
        templateString = template.stringValue;

        if (templateString.startsWith('<<')) {
          var result = await readTemplate(ann, templateString);
          if (result != null) {
            templateString = result[0];
            styleInject = result[1];
          }
        }

        templateString = codegenString(templateString);
      }

      styleInject = codegenString(styleInject);

      var mixins = (args.named['mixins'] as ListLiteral)?.elements ?? [];

      code = '''
static VueComponentConstructor constructor = new VueComponentConstructor(
  name: ${codegenString(name)},
  creator: $creator,
  template: $templateString,
  styleInject: $styleInject,
  props: {${info.props.map(codegenProp).join('\n')}},
  mixins: ${codegenConstructorList(mixins)},
$opts
);
      ''';

      if (ann.name.name == 'VueMixin') {
        rewriter.edit(cls.end-1, cls.end-1, r'''
  dynamic vuedart_get(String key);
  void vuedart_set(String key, dynamic value);
  dynamic $ref(String name);
        ''');
      }
    } else {
      var el = args.named['el']?.toSource() ?? 'null';

      code = '''
@override
VueAppConstructor get constructor => new VueAppConstructor(
  el: $el,
$opts
);
      ''';
    }

    rewriter.edit(cls.end-1, cls.end-1, code);
  }

  Future build() async {
    if (!await buildStep.canRead(inputId)) {
      return new Future.value();
    }

    var contents = await buildStep.readAsString(inputId);
    var lib = await buildStep.inputLibrary;
    source = new SourceFile.fromString(contents);
    rewriter = new TextEditTransaction(contents, source);

    var classes = getVueClasses(lib);
    if (classes.isEmpty) {
      return new Future.value();
    }

    for (var cls in classes) {
      await processClass(cls);
    }

    if (lib.entryPoint != null) {
      var components = <VueImportedComponent>[];
      components.addAll(getVueComponents(classes));

      for (var imported in lib.imports) {
        var importedClasses = getVueClasses(imported.importedLibrary);
        components.addAll(getVueComponents(importedClasses, imported.prefix?.name));

        if (importedClasses.isNotEmpty) {
          var renamed = new AssetId.resolve(imported.uri, from: inputId)
                                   .changeExtension('.vue.dart');
          rewriter.edit(imported.uriOffset, imported.uriEnd, "'${renamed.uri}'");
        }
      }

      if (components.isNotEmpty) {
        var body = lib.entryPoint.computeNode().functionExpression.body;
        if (!(body is BlockFunctionBody)) {
          error(body, 'Expected function block.');
          return new Future.value();
        }

        var offset = (body as BlockFunctionBody).block.leftBracket.end;
        rewriter.edit(offset, offset, components.map(codegenRegister).join());
      }
    }

    var printer = rewriter.commit();
    printer.build(null);
    // print(printer.text);
    buildStep.writeAsString(inputId.changeExtension('.vue.dart'), printer.text);

    return new Future.value();
  }
}


class _VuedartBuilder {
  const _VuedartBuilder();

  factory _VuedartBuilder.fromOptions(BuilderOptions options) =>
    const _VuedartBuilder();

  @override final buildExtensions = const {
    '.dart': const ['.vue.dart'],
  };

  @override
  Future build(BuildStep buildStep) async {
    return await new VuedartBuildContext(buildStep).build();
  }
}

Builder vuedartBuilder(BuilderOptions options) =>
  new _VuedartBuilder.fromOptions(options);
