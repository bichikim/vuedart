import 'package:vue/vue.dart';


@VueComponent(name: 'site-navbar', template: '<<')
class SiteNavbar extends VueComponentBase {
  SiteNavbar(context): super(context);

  @method
  String relUrl(String url) => nested != null ? '../$url' : url;

  @prop
  dynamic nested;
}
