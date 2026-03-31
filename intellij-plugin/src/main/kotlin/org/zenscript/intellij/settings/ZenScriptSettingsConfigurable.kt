package org.zenscript.intellij.settings

import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory
import com.intellij.openapi.options.Configurable
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.TextFieldWithBrowseButton
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent
import javax.swing.JPanel

class ZenScriptSettingsConfigurable(private val project: Project) : Configurable {

    private var stdlibPathField: TextFieldWithBrowseButton? = null
    private var mainPanel: JPanel? = null

    override fun getDisplayName(): String = "ZenScript"

    override fun createComponent(): JComponent {
        stdlibPathField = TextFieldWithBrowseButton().apply {
            addBrowseFolderListener(
                "Select ZenScript Stdlib Directory",
                "Path to the ZenScript standard library (containing prelude.zs)",
                project,
                FileChooserDescriptorFactory.createSingleFolderDescriptor()
            )
        }
        mainPanel = FormBuilder.createFormBuilder()
            .addLabeledComponent("Stdlib path:", stdlibPathField!!)
            .addComponentFillVertically(JPanel(), 0)
            .panel
        return mainPanel!!
    }

    override fun isModified(): Boolean {
        val settings = ZenScriptSettings.getInstance(project)
        return stdlibPathField?.text != settings.stdlibPath
    }

    override fun apply() {
        val settings = ZenScriptSettings.getInstance(project)
        settings.stdlibPath = stdlibPathField?.text ?: ""
    }

    override fun reset() {
        val settings = ZenScriptSettings.getInstance(project)
        stdlibPathField?.text = settings.stdlibPath
    }

    override fun disposeUIResources() {
        stdlibPathField = null
        mainPanel = null
    }
}
