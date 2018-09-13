use v6;
use JSON::ECMA262Regex;

class X::JSON::Schema::BadSchema is Exception {
    has $.path;
    has $.reason;

    method message() {
        "Schema invalid at $!path: $!reason"
    }
}

class X::JSON::Schema::Failed is Exception {
    has $.path;
    has $.reason;
    method message() {
        "Validation failed for $!path: $!reason"
    }
}

class JSON::Schema {
    # Role that describes a single check for a given path.
    # `chech` method is overloaded, with possible usage of additional per-class
    # attributes
    my role Check {
        has $.path;
        method check($value --> Nil) { ... }
    }

    my class AllCheck does Check {
        has $.native = True;
        has @.checks;
        method check($value --> Nil) {
            for @!checks.kv -> $i, $c {
                $c.check($value);
                CATCH {
                    when X::JSON::Schema::Failed {
                        my $path = $!native ?? .path !! "{.path}/{$i + 1}";
                        die X::JSON::Schema::Failed.new(:$path, reason => .reason);
                    }
                }
            }
        }
    }

    my class OrCheck does Check {
        has @.checks;
        method check($value --> Nil) {
            for @!checks.kv -> $i, $c {
                $c.check($value);
                return;
                CATCH {
                    when X::JSON::Schema::Failed {}
                }
            }
            die X::JSON::Schema::Failed.new(:$!path, :reason('Does not satisfy any check'));
        }
    }

    my role TypeCheck does Check {
        method check($value --> Nil) {
            unless $value.defined && $value ~~ $.type {
                die X::JSON::Schema::Failed.new(path => $.path, reason => $.reason);
            }
        }
    }

    my class NullCheck does TypeCheck {
        method check($value --> Nil) {
            unless $value ~~ Nil {
                die X::JSON::Schema::Failed.new(path => $.path, reason => 'Not a null');
            }
        }
    }

    my class BooleanCheck does TypeCheck {
        has $.reason = 'Not a boolean';
        has $.type = Bool;
    }

    my class ObjectCheck does TypeCheck {
        has $.reason = 'Not an object';
        has $.type = Associative;
    }

    my class ArrayCheck does TypeCheck {
        has $.reason = 'Not an array';
        has $.type = Positional;
    }

    my class NumberCheck does TypeCheck {
        has $.reason = 'Not a number';
        has $.type = Rat;
    }

    my class StringCheck does TypeCheck {
        has $.reason = 'Not a string';
        has $.type = Str;
    }

    my class IntegerCheck does TypeCheck {
        has $.reason = 'Not an integer';
        has $.type = Int;
    }

    my class EnumCheck does Check {
        has $.enum;
        method check($value --> Nil) {
            return if $value ~~ Nil && Nil (elem) $!enum;
            unless $value.defined && $value (elem) $!enum {
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("Value '$value' is outside of enumeration set by enum property");
            }
        }
    }

    my class ConstCheck does Check {
        has $.const;
        method check($value --> Nil) {
            unless $value eqv $!const {
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("Value '$value' does not match with constant $!const");   
            }
        }
    }

    my class MultipleOfCheck does Check {
        has UInt $.multi;
        method check($value --> Nil) {
            if $value ~~ Real {
                unless $value %% $!multi {
                    die X::JSON::Schema::Failed.new:
                        :$!path, :reason("Number is not multiple of $!multi");
                }
            }
        }
    }

    my role CmpCheck does Check {
        has Int $.border-value;

        method check($value --> Nil) {
            if $value ~~ Real {
                unless self.compare($value, $!border-value) {
                    die X::JSON::Schema::Failed.new:
                        path => $.path, :reason("$value is {self.reason} $!border-value");
                }
            }
        }
    }

    my class MinCheck does CmpCheck {
        method reason { 'less than' }
        method compare($value-to-compare, $border-value) { $value-to-compare >= $border-value }
    }

    my class MinExCheck does CmpCheck {
        method reason { 'less or equal than' }
        method compare($value-to-compare, $border-value) { $value-to-compare > $border-value }
    }

    my class MaxCheck does CmpCheck {
        method reason { 'more than' }
        method compare($value-to-compare, $border-value) { $value-to-compare <= $border-value }
    }

    my class MaxExCheck does CmpCheck {
        method reason { 'more or equal than' }
        method compare($value-to-compare, $border-value) { $value-to-compare < $border-value }
    }

    my class MinLengthCheck does Check {
        has Int $.value;
        method check($value --> Nil) {
            if $value ~~ Str && $value.defined && $value.codes < $!value {
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("String is less than $!value codepoints");
            }
        }
    }

    my class MaxLengthCheck does Check {
        has Int $.value;
        method check($value --> Nil) {
            if $value ~~ Str && $value.defined && $value.codes > $!value {
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("String is more than $!value codepoints");
            }
        }
    }

    my class PatternCheck does Check {
        has Str $.pattern;
        has Regex $!rx;
        submethod TWEAK() {
            use MONKEY-SEE-NO-EVAL;
            $!rx = EVAL 'rx:P5/' ~ $!pattern ~ '/';
        }
        method check($value --> Nil) {
            if $value ~~ Str && $value !~~ $!rx {
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("String does not match /$!pattern/");
            }
        }
    }

    my class MinItemsCheck does Check {
        has Int $.value;
        method check($value --> Nil) {
            if $value ~~ Positional && $value.elems < $!value {
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("Array has less than $!value elements");
            }
        }
    }

    my class MaxItemsCheck does Check {
        has Int $.value;
        method check($value --> Nil) {
            if $value ~~ Positional && $value.elems > $!value {
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("Array has less than $!value elements");
            }
        }
    }

    my class UniqueItemsCheck does Check {
        method check($value --> Nil) {
            if $value ~~ Positional && $value.elems != $value.unique(with => &[eqv]).elems {
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("Array has duplicated values");
            }
        }
    }

    my class ItemsByObjectCheck does Check {
        has Check $.check;

        method check($value --> Nil) {
            if $value ~~ Positional {
                for @$value -> $item {
                    $!check.check($item);
                }
            }
        }
    }

    my class ItemsByArraysCheck does Check {
        has Check @.checks;

        method check($value --> Nil) {
            if $value ~~ Positional {
                for @$value Z @!checks -> ($item, $check) {
                    $check.check($item);
                }
            }
        }
    }

    my class AdditionalItemsCheck does Check {
        has Check $.check;
        has Int $.size;

        method check($value --> Nil) {
            if $value ~~ Positional && $value.elems > $!size {
                for @$value[$!size..*] -> $item {
                    $!check.check($item);
                }
            }
        }
    }

    my class ContainsCheck does Check {
        has Check $.check;

        method check($value --> Nil) {
            if $value ~~ Positional {
                for @$value -> $item {
                    CATCH {
                        when X::JSON::Schema::Failed {}
                    }
                    $!check.check($item);
                    return;
                }
                die X::JSON::Schema::Failed.new:
                    :$!path, :reason("Array does not contain any element that is accepted by `contains` check");
            }
        }
    }

    has Check $!check;

    submethod BUILD(:%schema! --> Nil) {
        $!check = check-for('root', %schema);
    }

    sub check-for-type($path, $_) {
        when 'string' {
            StringCheck.new(:$path);
        }
        when 'integer' {
            IntegerCheck.new(:$path);
        }
        when 'null' {
            NullCheck.new(:$path);
        }
        when 'boolean' {
            BooleanCheck.new(:$path);
        }
        when 'object' {
            ObjectCheck.new(:$path);
        }
        when 'array' {
            ArrayCheck.new(:$path);
        }
        when 'number' {
            NumberCheck.new(:$path);
        }
        default {
            die X::JSON::Schema::BadSchema.new(:$path, :reason("Unrecognized type '$_'"));
        }
    }

    sub check-for($path, %schema) {
        my @checks;

        with %schema<type> {
            when Str {
                push @checks, check-for-type($path, $_);
            }
            when List {
                unless (all $_) ~~ Str {
                    die X::JSON::Schema::BadSchema.new:
                      :$path, :reason("Non-string elements are present in type constraint");
                }
                unless $_.unique ~~ $_ {
                    die X::JSON::Schema::BadSchema.new:
                      :$path, :reason("Non-unique elements are present in type constraint");
                }

                my @type-checks = $_.map({ check-for-type($path, $_) });
                push @checks, OrCheck.new(:path("$path/anyOf"),
                                          checks => @type-checks);
            }
            default {
                die X::JSON::Schema::BadSchema.new(:$path, :reason("Type property must be a string"));
            }
        }

        with %schema<enum> {
            unless $_ ~~ Positional {
                die X::JSON::Schema::BadSchema.new:
                :$path, :reason("enum property value must be an array");
            }
            push @checks, EnumCheck.new(:$path, enum => $_);
        }

        with %schema<const> {
            push @checks, ConstCheck.new(:$path, const => $_);
        }

        with %schema<multipleOf> {
            when $_ ~~ Int && $_ > 0 {
                push @checks, MultipleOfCheck.new(:$path, multi => $_);
            }
            default {
                die X::JSON::Schema::BadSchema.new:
                    :$path, :reason("The multipleOf property must be a non-negative integer");
            }
        }

        my %num-keys = minimum => MinCheck, minimumExclusive => MinExCheck,
                       maximum => MaxCheck, maximumExclusive => MaxExCheck;
        for %num-keys.kv -> $k, $v {
            with %schema{$k} {
                unless $_ ~~ Real {
                    die X::JSON::Schema::BadSchema.new:
                        :$path, :reason("The $k property must be a number");
                }
                push @checks, $v.new(:$path, border-value => $_);
            }
        }

        my %str-keys = minLength => MinLengthCheck, maxLength => MaxLengthCheck;
        for %str-keys.kv -> $prop, $check {
            with %schema{$prop} {
                when UInt {
                    push @checks, $check.new(:$path, value => $_);
                }
                default {
                    die X::JSON::Schema::BadSchema.new:
                        :$path, :reason("The $prop property must be a non-negative integer");
                }
            }
        }

        with %schema<pattern> {
            when Str {
                if ECMA262Regex.parse($_) {
                    push @checks, PatternCheck.new(:$path, :pattern($_));
                }
                else {
                    die X::JSON::Schema::BadSchema.new:
                        :$path, :reason("The pattern property must be an ECMA 262 regex");
                }
            }
            default {
                die X::JSON::Schema::BadSchema.new:
                    :$path, :reason("The pattern property must be a string");
            }
        }

        with %schema<items> {
            when Associative {
                push @checks, ItemsByObjectCheck.new(:$path, check => check-for($path, $_));
            }
            when Positional {
                unless ($_.all) ~~ Hash {
                    die X::JSON::Schema::BadSchema.new:
                    :$path, :reason("The item property array must contain only objects");
                }

                my @items-checks = $_.map({ check-for($path, $_) });
                push @checks, ItemsByArraysCheck.new(:$path, checks => @items-checks);
            }
            default {
                die X::JSON::Schema::BadSchema.new:
                    :$path, :reason("The item property must be a JSON Schema or array of JSON Schema objects");
            }
        }

        with %schema<additionalItems> {
            when Associative {
                if %schema<items> ~~ Positional {
                    my $check = check-for($path, $_);
                    push @checks, AdditionalItemsCheck.new(:$path, :$check, size => %schema<items>.elems);
                }
            }
            default {
                die X::JSON::Schema::BadSchema.new:
                    :$path, :reason("The additionalItems property must be a JSON Schema object");
            }
        }

        my %array-keys = minItems => MinItemsCheck, maxItems => MaxItemsCheck;
        for %array-keys.kv -> $prop, $check {
            with %schema{$prop} {
                when UInt {
                    push @checks, $check.new(:$path, value => $_);
                }
                default {
                    die X::JSON::Schema::BadSchema.new:
                        :$path, :reason("The $prop property must be a non-negative integer");
                }
            }

        }
        with %schema<uniqueItems> {
            when $_ === True {
                push @checks, UniqueItemsCheck.new(:$path);
            }
            when  $_ === False {}
            default {
                die X::JSON::Schema::BadSchema.new:
                    :$path, :reason("The uniqueItems property must be a boolean");
            }
        }

        with %schema<contains> {
            when Associative {
                my $check = check-for($path, $_);
                push @checks, ContainsCheck.new(:$path, :$check);
            }
            default {
                die X::JSON::Schema::BadSchema.new:
                    :$path, :reason("The contains property must be a JSON Schema object");
            }
        }

        @checks == 1 ?? @checks[0] !! AllCheck.new(:@checks);
    }

    method validate($value --> True) {
        $!check.check($value);
        CATCH {
            when X::JSON::Schema::Failed {
                fail $_;
            }
        }
    }
}
