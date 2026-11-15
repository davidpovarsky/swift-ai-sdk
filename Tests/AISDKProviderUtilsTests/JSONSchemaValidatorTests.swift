import Testing
@testable import AISDKProvider
@testable import AISDKProviderUtils

@Suite("JSONSchemaValidator")
struct JSONSchemaValidatorTests {
    @Test("boolean schemas apply at the root and nested instance locations")
    func booleanSchemasRejectAtRootAndNestedLocations() throws {
        let values: [JSONValue] = [.null, .bool(false), .number(1), .string("😀"), .array([]), .object([:])]
        for value in values {
            #expect(!JSONSchemaValidator(schema: .bool(false)).validate(value: value).isEmpty)
            #expect(JSONSchemaValidator(schema: .bool(true)).validate(value: value).isEmpty)
        }
        let object = JSONSchemaValidator(schema: .object([
            "type": .string("object"), "properties": .object(["blocked": .bool(false)])
        ]))
        #expect(!object.validate(value: .object(["blocked": .null])).isEmpty)
        #expect(object.validate(value: .object([:])).isEmpty)
        let array = JSONSchemaValidator(schema: .object(["type": .string("array"), "items": .bool(false)]))
        #expect(array.validate(value: .array([])).isEmpty)
        #expect(!array.validate(value: .array([.null])).isEmpty)
        let combined = JSONSchemaValidator(schema: .object(["allOf": .array([.bool(true), .bool(false)])]))
        #expect(!combined.validate(value: .object([:])).isEmpty)
    }

    @Test("length counts Unicode scalars while regex ranges retain UTF-16 offsets")
    func unicodeScalarLengthsDoNotCountUTF16UnitsOrGraphemeClusters() throws {
        let one = JSONSchemaValidator(schema: .object([
            "type": .string("string"), "minLength": .number(1), "maxLength": .number(1)
        ]))
        #expect(one.validate(value: .string("😀")).isEmpty)
        #expect(one.validate(value: .string("א")).isEmpty)
        #expect(!one.validate(value: .string("e\u{301}")).isEmpty)
        #expect(!one.validate(value: .string("👨‍👩‍👧‍👦")).isEmpty)
        #expect(!one.validate(value: .string("")).isEmpty)
        let two = JSONSchemaValidator(schema: .object([
            "type": .string("string"), "minLength": .number(2), "maxLength": .number(2)
        ]))
        #expect(two.validate(value: .string("e\u{301}")).isEmpty)
        #expect(!two.validate(value: .string("😀")).isEmpty)
        let pattern = JSONSchemaValidator(schema: .object([
            "type": .string("string"), "minLength": .number(2), "maxLength": .number(2), "pattern": .string("^😀a$")
        ]))
        #expect(pattern.validate(value: .string("😀a")).isEmpty)
    }

    @Test("the public JSON Schema facade preserves boolean and Unicode validation")
    func publicFacadeEnforcesFalseSchemaAndUnicodeScalarLength() async throws {
        let unicode: Schema<JSONValue> = jsonSchema(.object([
            "type": .string("string"), "maxLength": .number(1)
        ]))
        switch await unicode.validate("😀") {
        case .success(let value): #expect(value == .string("😀"))
        case .failure: Issue.record("The public facade rejected one Unicode code point")
        }
        let rejected: Schema<JSONValue> = jsonSchema(.bool(false))
        switch await rejected.validate(["anything": 1]) {
        case .success: Issue.record("The public facade admitted a false schema")
        case .failure: break
        }
    }

    @Test("anyOf does not bypass type validation")
    func anyOfDoesNotBypassTypeValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "anyOf": .array([
                .object(["format": .string("uuid")])
            ])
        ])

        let validator = JSONSchemaValidator(schema: schema)
        #expect(!validator.validate(value: .number(1)).isEmpty)
    }

    @Test("validates pattern constraints in allOf subschemas without explicit types")
    func allOfPatternWithoutTypeValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "allOf": .array([
                .object(["pattern": .string("^a")]),
                .object(["pattern": .string("b$")])
            ])
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("ab")).isEmpty)
        #expect(!validator.validate(value: .string("ac")).isEmpty)
    }

    @Test("supports type unions via type arrays")
    func typeArrayUnionValidation() async throws {
        let schema: JSONValue = .object([
            "type": .array([.string("string"), .string("null")])
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("hello")).isEmpty)
        #expect(validator.validate(value: .null).isEmpty)
        #expect(!validator.validate(value: .number(1)).isEmpty)
    }

    @Test("validates enum constraints")
    func enumValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "enum": .array([.string("a"), .string("b")])
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("a")).isEmpty)
        #expect(!validator.validate(value: .string("c")).isEmpty)
    }

    @Test("validates const constraints")
    func constValidation() async throws {
        let schema: JSONValue = .object([
            "const": .string("fixed")
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("fixed")).isEmpty)
        #expect(!validator.validate(value: .string("other")).isEmpty)
    }

    @Test("validates integer type")
    func integerTypeValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("integer")
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .number(1)).isEmpty)
        #expect(!validator.validate(value: .number(1.5)).isEmpty)
        #expect(!validator.validate(value: .string("1")).isEmpty)
    }

    @Test("validates array length constraints")
    func arrayLengthConstraints() async throws {
        let schema: JSONValue = .object([
            "type": .string("array"),
            "minItems": .number(2),
            "maxItems": .number(2),
            "items": .object(["type": .string("number")])
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .array([.number(1), .number(2)])).isEmpty)
        #expect(!validator.validate(value: .array([.number(1)])).isEmpty)
        #expect(!validator.validate(value: .array([.number(1), .number(2), .number(3)])).isEmpty)
    }

    @Test("validates string length and pattern constraints")
    func stringConstraints() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "minLength": .number(2),
            "maxLength": .number(3),
            "pattern": .string("^[a-z]+$")
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("ab")).isEmpty)
        #expect(!validator.validate(value: .string("a")).isEmpty)
        #expect(!validator.validate(value: .string("abcd")).isEmpty)
        #expect(!validator.validate(value: .string("A1")).isEmpty)
    }

    @Test("validates format uuid constraints")
    func uuidFormatConstraints() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "format": .string("uuid")
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("550e8400-e29b-41d4-a716-446655440000")).isEmpty)
        #expect(!validator.validate(value: .string("not-a-uuid")).isEmpty)
    }

    @Test("validates format email constraints")
    func emailFormatConstraints() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "format": .string("email")
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("a+b@example.com")).isEmpty)
        #expect(!validator.validate(value: .string("not-an-email")).isEmpty)
    }

    @Test("validates format uri constraints")
    func uriFormatConstraints() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "format": .string("uri")
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("https://example.com")).isEmpty)
        #expect(!validator.validate(value: .string("foo")).isEmpty)
        #expect(!validator.validate(value: .string("http://")).isEmpty)
    }

    @Test("validates anyOf format constraints")
    func anyOfFormatConstraints() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "anyOf": .array([
                .object(["format": .string("ipv4")]),
                .object(["format": .string("ipv6")])
            ])
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("127.0.0.1")).isEmpty)
        #expect(validator.validate(value: .string("2001:DB8::1")).isEmpty)
        #expect(!validator.validate(value: .string("999.0.0.1")).isEmpty)
    }

    @Test("validates contentEncoding base64 constraints")
    func contentEncodingBase64Constraints() async throws {
        let schema: JSONValue = .object([
            "type": .string("string"),
            "contentEncoding": .string("base64")
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .string("Zm9v")).isEmpty) // "foo"
        #expect(!validator.validate(value: .string("not-base64")).isEmpty)
    }

    @Test("validates numeric bounds")
    func numericBoundsValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("number"),
            "minimum": .number(1),
            "maximum": .number(3),
            "exclusiveMinimum": .number(0),
            "exclusiveMaximum": .number(4)
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .number(2)).isEmpty)
        #expect(!validator.validate(value: .number(0)).isEmpty)
        #expect(!validator.validate(value: .number(4)).isEmpty)
    }

    @Test("validates tuple schemas via items array and additionalItems")
    func tupleValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("array"),
            "minItems": .number(2),
            "items": .array([
                .object(["type": .string("number")]),
                .object(["type": .string("string")])
            ]),
            "additionalItems": .bool(false)
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .array([.number(1), .string("ok")])).isEmpty)
        #expect(!validator.validate(value: .array([.number(1), .number(2)])).isEmpty)
        #expect(!validator.validate(value: .array([.number(1), .string("ok"), .string("extra")])).isEmpty)

        let restSchema: JSONValue = .object([
            "type": .string("array"),
            "minItems": .number(2),
            "items": .array([
                .object(["type": .string("number")]),
                .object(["type": .string("string")])
            ]),
            "additionalItems": .object(["type": .string("number")])
        ])

        let restValidator = JSONSchemaValidator(schema: restSchema)
        #expect(restValidator.validate(value: .array([.number(1), .string("ok"), .number(3)])).isEmpty)
        #expect(!restValidator.validate(value: .array([.number(1), .string("ok"), .string("bad")])).isEmpty)
    }

    @Test("validates uniqueItems constraint")
    func uniqueItemsValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("array"),
            "uniqueItems": .bool(true)
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .array([.number(1), .number(2)])).isEmpty)
        #expect(!validator.validate(value: .array([.number(1), .number(1)])).isEmpty)
    }

    @Test("validates multipleOf constraint")
    func multipleOfValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("number"),
            "multipleOf": .number(2)
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .number(4)).isEmpty)
        #expect(!validator.validate(value: .number(3)).isEmpty)
    }

    @Test("validates object minProperties/maxProperties constraints")
    func objectPropertiesBounds() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "minProperties": .number(2),
            "maxProperties": .number(2)
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .object(["a": .string("1"), "b": .string("2")])).isEmpty)
        #expect(!validator.validate(value: .object(["a": .string("1")])).isEmpty)
        #expect(!validator.validate(value: .object(["a": .string("1"), "b": .string("2"), "c": .string("3")])).isEmpty)
    }

    @Test("resolves $ref pointers into definitions")
    func refValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "definitions": .object([
                "__schema0": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")]),
                        "number": .object(["type": .string("number")]),
                    ]),
                    "required": .array([.string("text"), .string("number")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "properties": .object([
                "group1": .object(["$ref": .string("#/definitions/__schema0")]),
            ]),
            "required": .array([.string("group1")]),
            "additionalProperties": .bool(false),
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .object([
            "group1": .object(["text": .string("hi"), "number": .number(1)]),
        ])).isEmpty)

        #expect(!validator.validate(value: .object([
            "group1": .object(["text": .string("hi")]),
        ])).isEmpty)
    }

    @Test("supports recursive $ref schemas")
    func recursiveRefValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "definitions": .object([
                "__schema0": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "subcategories": .object([
                            "type": .string("array"),
                            "items": .object(["$ref": .string("#/definitions/__schema0")]),
                        ]),
                    ]),
                    "required": .array([.string("name"), .string("subcategories")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "properties": .object([
                "category": .object(["$ref": .string("#/definitions/__schema0")]),
            ]),
            "required": .array([.string("category")]),
            "additionalProperties": .bool(false),
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .object([
            "category": .object([
                "name": .string("root"),
                "subcategories": .array([
                    .object([
                        "name": .string("child"),
                        "subcategories": .array([]),
                    ]),
                ]),
            ]),
        ])).isEmpty)

        #expect(!validator.validate(value: .object([
            "category": .object([
                "name": .string("root"),
                "subcategories": .array([
                    .object([
                        "subcategories": .array([]),
                    ]),
                ]),
            ]),
        ])).isEmpty)
    }

    @Test("supports if/then/else conditional keywords")
    func conditionalKeywordsValidation() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object(["type": .string("string")]),
                "value": .object(["type": .string("string")]),
                "count": .object(["type": .string("number")]),
            ]),
            "if": .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object(["const": .string("text")]),
                ]),
                "required": .array([.string("kind")]),
            ]),
            "then": .object([
                "type": .string("object"),
                "required": .array([.string("value")]),
            ]),
            "else": .object([
                "type": .string("object"),
                "required": .array([.string("count")]),
            ]),
            "additionalProperties": .bool(false),
        ])

        let validator = JSONSchemaValidator(schema: schema)

        #expect(validator.validate(value: .object([
            "kind": .string("text"),
            "value": .string("ok"),
        ])).isEmpty)

        #expect(!validator.validate(value: .object([
            "kind": .string("text"),
        ])).isEmpty)

        #expect(validator.validate(value: .object([
            "kind": .string("num"),
            "count": .number(3),
        ])).isEmpty)

        #expect(!validator.validate(value: .object([
            "kind": .string("num"),
        ])).isEmpty)
    }

    @Test("reports unresolved $ref pointers as issues")
    func unresolvedRefValidation() async throws {
        let schema: JSONValue = .object([
            "$ref": .string("#/definitions/does_not_exist"),
            "definitions": .object([:]),
        ])

        let validator = JSONSchemaValidator(schema: schema)
        #expect(!validator.validate(value: .object([:])).isEmpty)
    }
}
