// An anonymous default class whose static method `name` replaces the name "default".
export default (class {
  static name(): string {
    return "name method";
  }
});
