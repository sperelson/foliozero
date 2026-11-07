import Foundation

/// The custom filters Paperless-ngx registers (src/documents/templating/filters.py and filepath.py).
enum PaperlessFilters {
    static let all: [String: TemplateEnvironment.FilterImplementation] = [
        "slugify": slugify,
        "datetime": datetime,
        "localize_date": localizeDate,
        "get_cf_value": getCustomFieldValue,
    ]

    /// Django's `slugify`: NFKD to ASCII (unless `allow_unicode`), drop characters that are not word
    /// characters, spaces or hyphens, lowercase, collapse runs of spaces and hyphens to one hyphen,
    /// and strip leading and trailing hyphens and underscores.
    static func slugify(_ call: FilterCall) throws -> TemplateValue {
        let allowUnicode = Py.truthy(try call.bind([("allow_unicode", false)])[0])
        var text = Py.str(call.value)
        if allowUnicode {
            text = text.precomposedStringWithCompatibilityMapping
        } else {
            text = Py.string(text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII))
        }
        var kept: [Unicode.Scalar] = []
        for scalar in text.lowercased().unicodeScalars
        where Py.isWordCharacter(scalar) || Py.isWhitespace(scalar) || scalar == "-" {
            kept.append(scalar)
        }
        var collapsed: [Unicode.Scalar] = []
        var inRun = false
        for scalar in kept {
            if scalar == "-" || Py.isWhitespace(scalar) {
                if !inRun { collapsed.append("-") }
                inRun = true
            } else {
                collapsed.append(scalar)
                inRun = false
            }
        }
        return .string(PyString.strip(Py.string(collapsed), chars: "-_"))
    }

    /// Paperless-ngx `format_datetime`: Python `strftime` on a date, or on a string parsed with
    /// Django's `parse_datetime` / `parse_date`.
    static func datetime(_ call: FilterCall) throws -> TemplateValue {
        let format = Py.str(try call.bind([("format", nil)])[0])
        let value: PyDateTime
        switch call.value.plain {
        case .date:
            value = PyDateTime(call.value)!
        case .string(let text):
            guard let parsed = DateSupport.parseISO(text, defaultTimeZone: call.environment.timeZone) else {
                throw RuntimeFailure("Invalid date or datetime string: \(Py.reprString(text))")
            }
            value = parsed
        default:
            throw RuntimeFailure("'\(Py.typeName(call.value))' object has no attribute 'strftime'")
        }
        return .string(try DateSupport.strftime(format, value, limits: call.limits))
    }

    private static let localeIdentifiers = Set(Locale.availableIdentifiers)

    /// Paperless-ngx `localize_date`: formats with a preset (`short`, `medium`, `long`, `full`) or a
    /// CLDR pattern in the given locale. Uses Foundation's `DateFormatter`, whose CLDR data can differ
    /// in small ways from Babel's (for example "GMT" instead of "UTC" for the `z` pattern).
    static func localizeDate(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("format", nil), ("locale", nil)])
        let format = Py.str(bound[0])
        let localeName = Py.str(bound[1])

        let value: PyDateTime
        switch call.value.plain {
        case .date:
            value = PyDateTime(call.value)!
        case .string(let text):
            guard let parsed = DateSupport.parseISO(text, defaultTimeZone: call.environment.timeZone) else {
                throw RuntimeFailure("Unsupported type <class 'NoneType'> for localize_date")
            }
            value = parsed
        default:
            let pythonType = switch call.value {
            case .none: "NoneType"
            default: Py.typeName(call.value)
            }
            throw RuntimeFailure("Unsupported type <class '\(pythonType)'> for localize_date")
        }

        let identifier = localeName.replacingOccurrences(of: "-", with: "_")
        let language = identifier.split(separator: "_").first.map(String.init) ?? identifier
        guard !identifier.isEmpty,
              localeIdentifiers.contains(identifier) || localeIdentifiers.contains(language) else {
            throw RuntimeFailure("Invalid locale identifier: \(localeName)")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: identifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = formatter.locale
        calendar.timeZone = value.timeZone
        formatter.calendar = calendar
        formatter.timeZone = value.timeZone
        let presets: [String: DateFormatter.Style] = ["short": .short, "medium": .medium, "long": .long, "full": .full]
        if let style = presets[format] {
            formatter.dateStyle = style
            formatter.timeStyle = value.includesTime ? style : .none
        } else {
            formatter.dateFormat = format
        }
        return .string(try call.limits.check(formatter.string(from: value.date)))
    }

    /// Paperless-ngx `get_cf_value`: reads `custom_fields[name]["value"]`, falling back to `default`
    /// when the field is missing or its value is None.
    static func getCustomFieldValue(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("name", nil), ("default", TemplateValue.none)])
        let name = Py.str(bound[0])
        guard case .dict(let fields) = call.value else {
            throw RuntimeFailure("get_cf_value expects the custom_fields mapping, not \(Py.typeName(call.value))")
        }
        if case .dict(let field)? = fields[name], let value = field["value"] {
            switch value {
            case .none, .undefined: break
            default: return value
            }
        }
        return bound[1]
    }
}
