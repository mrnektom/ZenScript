package org.zenscript.intellij.highlighting

import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.openapi.fileTypes.SyntaxHighlighter
import com.intellij.openapi.options.colors.AttributesDescriptor
import com.intellij.openapi.options.colors.ColorDescriptor
import com.intellij.openapi.options.colors.ColorSettingsPage
import javax.swing.Icon

class ZenScriptColorSettingsPage : ColorSettingsPage {

    companion object {
        private val DESCRIPTORS = arrayOf(
            AttributesDescriptor("Keyword", ZenScriptSyntaxHighlighter.KEYWORD),
            AttributesDescriptor("Number", ZenScriptSyntaxHighlighter.NUMBER),
            AttributesDescriptor("String", ZenScriptSyntaxHighlighter.STRING),
            AttributesDescriptor("Line comment", ZenScriptSyntaxHighlighter.LINE_COMMENT),
            AttributesDescriptor("Operator", ZenScriptSyntaxHighlighter.OPERATION_SIGN),
            AttributesDescriptor("Parentheses", ZenScriptSyntaxHighlighter.PARENTHESES),
            AttributesDescriptor("Braces", ZenScriptSyntaxHighlighter.BRACES),
            AttributesDescriptor("Brackets", ZenScriptSyntaxHighlighter.BRACKETS),
            AttributesDescriptor("Comma", ZenScriptSyntaxHighlighter.COMMA),
            AttributesDescriptor("Semicolon", ZenScriptSyntaxHighlighter.SEMICOLON),
            AttributesDescriptor("Identifier", ZenScriptSyntaxHighlighter.IDENTIFIER),
            AttributesDescriptor("Function declaration", ZenScriptSyntaxHighlighter.FUNCTION_NAME),
            AttributesDescriptor("Function call", ZenScriptSyntaxHighlighter.FUNCTION_CALL),
            AttributesDescriptor("Field", ZenScriptSyntaxHighlighter.FIELD_NAME),
            AttributesDescriptor("Bad character", ZenScriptSyntaxHighlighter.BAD_CHARACTER),
        )

        private val ADDITIONAL_HIGHLIGHTING_TAG_TO_DESCRIPTOR_MAP = mapOf(
            "fnDecl" to ZenScriptSyntaxHighlighter.FUNCTION_NAME,
            "fnCall" to ZenScriptSyntaxHighlighter.FUNCTION_CALL,
            "field" to ZenScriptSyntaxHighlighter.FIELD_NAME,
        )
    }

    override fun getIcon(): Icon? = null

    override fun getHighlighter(): SyntaxHighlighter = ZenScriptSyntaxHighlighter()

    override fun getDemoText(): String = """
        // ZenScript example
        struct Point {
            <field>x</field>: i32;
            <field>y</field>: i32;
        }

        fn <fnDecl>distance</fnDecl>(p: Point): i32 {
            let dx = p.<field>x</field>;
            let dy = p.<field>y</field>;
            return <fnCall>sqrt</fnCall>(dx * dx + dy * dy);
        }

        fn <fnDecl>main</fnDecl>() {
            let p = Point { x: 3, y: 4 };
            let d = <fnCall>distance</fnCall>(p);
        }
    """.trimIndent()

    override fun getAdditionalHighlightingTagToDescriptorMap(): Map<String, TextAttributesKey> =
        ADDITIONAL_HIGHLIGHTING_TAG_TO_DESCRIPTOR_MAP

    override fun getAttributeDescriptors(): Array<AttributesDescriptor> = DESCRIPTORS

    override fun getColorDescriptors(): Array<ColorDescriptor> = ColorDescriptor.EMPTY_ARRAY

    override fun getDisplayName(): String = "ZenScript"
}
