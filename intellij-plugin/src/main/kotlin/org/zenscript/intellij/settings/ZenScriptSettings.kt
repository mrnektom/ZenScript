package org.zenscript.intellij.settings

import com.intellij.openapi.components.*
import com.intellij.openapi.project.Project

@Service(Service.Level.PROJECT)
@State(
    name = "ZenScriptSettings",
    storages = [Storage("zenscript.xml")]
)
class ZenScriptSettings : PersistentStateComponent<ZenScriptSettings.State> {

    data class State(var stdlibPath: String = "")

    private var myState = State()

    override fun getState(): State = myState

    override fun loadState(state: State) {
        myState = state
    }

    var stdlibPath: String
        get() = myState.stdlibPath
        set(value) { myState.stdlibPath = value }

    companion object {
        fun getInstance(project: Project): ZenScriptSettings =
            project.getService(ZenScriptSettings::class.java)
    }
}
