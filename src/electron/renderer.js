import { Elm } from "../elm/Electron";
const Mousetrap = require("mousetrap");
const helpers = require("../shared/doc-helpers");
const container = require("Container");

// Init Vars

window.elmMessages = [];
let lastActivesScrolled = null;
let lastColumnScrolled = null;
let ticking = false;
let DIRTY = true
const localStore = container.localStore;

// Init Elm
let gingkoElectron;

const init = async function (filePath, fileData, undoData) {
  let timestamp = Date.now();
  let globalData =
    { seed : timestamp
    , currentTime : timestamp
    , isMac : false
    };
  console.log(undoData)
  gingkoElectron = Elm.Electron.init({ flags: { filePath, fileData, undoData, globalData } })

  gingkoElectron.ports.infoForOutside.subscribe(function (elmdata) {
    fromElm(elmdata.tag, elmdata.data);
  });
};

window.electronAPI.fileReceived(async (event, value) => {
  if (value.fileData !== null) DIRTY = false
  await init(value.filePath, value.fileData, value.undoData)
})

window.electronAPI.fileSaved(async (event, data) => {
  DIRTY = false
  toElm(data, 'docMsgs', 'SavedToFile')
})

window.onbeforeunload = (e) => {
  if (DIRTY) {
    setTimeout(window.electronAPI.closeWindow, 200)
    e.returnValue = false
  }
}

/* === Elm / JS Interop === */

const fromElm = (msg, elmData) => {
  window.elmMessages.push({ tag: msg, data: elmData })
  window.elmMessages = window.elmMessages.slice(-10)

  const casesElectron = {
    SetDirty: () => {
      DIRTY = elmData
    },

    CommitData: () => {
      window.electronAPI.commitData(elmData)
    },

    DragStart: () => {
      const cardElement = elmData.target.parentElement
      const cardId = cardElement.id.replace(/^card-/, '')
      elmData.dataTransfer.setDragImage(cardElement, 0, 0)
      elmData.dataTransfer.setData('text', '')
      toElm(cardId, 'docMsgs', 'DragStarted')
    },

    SaveToFile: () => {
      window.electronAPI.saveFile(elmData)
    }
  }

  let params = { localStore, lastColumnScrolled, lastActivesScrolled, ticking };

  let cases = Object.assign(helpers.casesShared(elmData, params), casesElectron);

  try {
    cases[msg]();
  } catch (err) {
    console.error("Unexpected message from Elm : ", msg, elmData, err);
  }
}

function toElm(data, portName, tagName) {
  let portExists = gingkoElectron.ports.hasOwnProperty(portName);
  let tagGiven = typeof tagName == "string";

  if (portExists) {
    var dataToSend;

    if (tagGiven) {
      dataToSend = { tag: tagName, data: data };
    } else {
      dataToSend = data;
    }
    gingkoElectron.ports[portName].send(dataToSend);
  } else {
    console.error("Unknown port", portName, data);
  }
}


/* === Keyboard === */

Mousetrap.bind(helpers.shortcuts.filter((x) => x !== 'mod+s'), function (e, s) {
  switch (s) {
    case "enter":
      if (document.activeElement.nodeName == "TEXTAREA") {
        return;
      } else {
        toElm("enter","docMsgs", "Keyboard");
      }
      break;

    case "mod+c":
      let exportPreview = document.getElementById("export-preview");
      if (exportPreview !== null) {
        return;
      } else {
        toElm("mod+c","docMsgs", "Keyboard");
      }
      break;

    case "mod+v":
    case "mod+shift+v":
      let elmTag = s === "mod+v" ? "Paste" : "PasteInto";

      navigator.clipboard.readText()
        .then(clipString => {
          try {
            let clipObj = JSON.parse(clipString);
            toElm(clipObj, "docMsgs", elmTag)
          } catch {
            toElm(clipString, "docMsgs", elmTag)
          }
        });
      break;

    case "alt+0":
    case "alt+1":
    case "alt+2":
    case "alt+3":
    case "alt+4":
    case "alt+5":
    case "alt+6":
      if (document.activeElement.nodeName == "TEXTAREA") {
        let num = Number(s[s.length - 1]);
        let currentText = document.activeElement.value;
        let newText = currentText.replace(/^(#{0,6}) ?(.*)/, num === 0 ? '$2' : '#'.repeat(num) + ' $2');
        document.activeElement.value = newText;
        DIRTY = true;
        toElm(newText, "docMsgs", "FieldChanged");

        let cardElementId = document.activeElement.id.replace(/^card-edit/, "card");
        let card = document.getElementById(cardElementId);
        if (card !== null) {
          card.dataset.clonedContent = newText;
        }
      }
      break;

    default:
      toElm(s, "docMsgs", "Keyboard");
  }

  if (helpers.needOverride.includes(s)) {
    return false;
  }
});


/* === DOM manipulation === */

const observer = helpers.getObserver(toElm);
const observerConfig = { childList: true, subtree: true };
observer.observe(document.body, observerConfig);
