#= require trix/models/block
#= require trix/models/splittable_list
#= require trix/models/location_range
#= require trix/models/position_range
#= require trix/models/html_parser

editOperationLog = Trix.Logger.get("editOperations")

class Trix.Document extends Trix.Object
  @fromJSON: (documentJSON) ->
    blocks = for blockJSON in documentJSON
      Trix.Block.fromJSON blockJSON
    new this blocks

  @fromHTML: (html) ->
    Trix.HTMLParser.parse(html).getDocument()

  @fromString: (string, textAttributes) ->
    text = Trix.Text.textForStringWithAttributes(string, textAttributes)
    new this [new Trix.Block text]

  constructor: (blocks = []) ->
    super
    @editDepth = 0
    @editCount = 0

    @blockList = new Trix.SplittableList blocks
    @ensureDocumentHasBlock()

    @attachments = new Trix.Set
    @attachments.delegate = this

    @refresh()

  ensureDocumentHasBlock: ->
    if @blockList.length is 0
      @blockList = new Trix.SplittableList [new Trix.Block]

  isEmpty: ->
    @blockList.length is 1 and (
      block = @getBlockAtIndex(0)
      block.isEmpty() and not block.hasAttributes()
    )

  copy: ->
    new @constructor @blockList.toArray()

  copyUsingObjectsFromDocument: (sourceDocument) ->
    objectMap = new Trix.ObjectMap sourceDocument.getObjects()
    @copyUsingObjectMap(objectMap)

  copyUsingObjectMap: (objectMap) ->
    blocks = for block in @getBlocks()
      if mappedBlock = objectMap.find(block)
        mappedBlock
      else
        block.copyUsingObjectMap(objectMap)
    new @constructor blocks

  edit = (name, fn) -> ->
    @beginEditing()
    fn.apply(this, arguments)
    @ensureDocumentHasBlock()

    editOperationLog.group(name)
    editOperationLog.log(format(object)...) for object in arguments
    editOperationLog.groupEnd()

    @endEditing()

  format = (object) ->
    if (value = object?.toConsole?())?
      ["%o%c%s%c", object, "color: #888", value, "color: auto"]
    else if typeof object is "string"
      ["%s", object]
    else
      ["%o", object]

  edit: edit "edit", (fn) -> fn()

  beginEditing: ->
    if @editDepth++ is 0
      @editCount++

      editOperationLog.group("Document #{@id}: Edit operation #{@editCount}")
      editOperationLog.groupCollapsed("Backtrace")
      editOperationLog.trace()
      editOperationLog.groupEnd()

    this

  endEditing: ->
    if --@editDepth is 0
      @refresh()
      @delegate?.didEditDocument?(this)

      editOperationLog.groupEnd()

    this

  insertDocumentAtPositionRange: edit "insertDocumentAtPositionRange", (document, positionRange) ->
    positionRange = Trix.PositionRange.box(positionRange)
    position = positionRange.start

    block = @getBlockAtPosition(position)
    position++ if @getPieceAtPosition(positionRange.end).isBlockBreak()

    @removeTextAtPositionRange(positionRange)
    @blockList = @blockList.insertSplittableListAtPosition(document.blockList, position)

  replaceDocument: edit "replaceDocument", (document) ->
    @blockList = document.blockList.copy()

  insertTextAtPositionRange: edit "insertTextAtPositionRange", (text, positionRange) ->
    positionRange = Trix.PositionRange.box(positionRange)
    locationRange = @locationRangeFromPositionRange(positionRange)

    @removeTextAtPositionRange(positionRange)
    @blockList = @blockList.editObjectAtIndex locationRange.index, (block) ->
      block.copyWithText(block.text.insertTextAtPosition(text, locationRange.offset))

  removeTextAtPositionRange: edit "removeTextAtPositionRange", (positionRange) ->
    locationRange = @locationRangeFromPositionRange(positionRange)
    return if locationRange.isCollapsed()

    leftIndex = locationRange.start.index
    leftBlock = @getBlockAtIndex(leftIndex)
    leftText = leftBlock.text.getTextAtRange([0, locationRange.start.offset])

    rightIndex = locationRange.end.index
    rightBlock = @getBlockAtIndex(rightIndex)
    rightText = rightBlock.text.getTextAtRange([locationRange.end.offset, rightBlock.getLength()])

    text = leftText.appendText(rightText)
    block = leftBlock.copyWithText(text)
    blocks = @blockList.toArray()
    affectedBlockCount = rightIndex + 1 - leftIndex
    blocks.splice(leftIndex, affectedBlockCount, block)

    @blockList = new Trix.SplittableList blocks

  moveTextFromPositionRangeToPosition: edit "moveTextFromPositionRangeToPosition", (positionRange, position) ->
    positionRange = Trix.PositionRange.box(positionRange)
    return if positionRange.start <= position <= positionRange.end

    document = @getDocumentAtPositionRange(positionRange)
    @removeTextAtPositionRange(positionRange)

    movingRightward = positionRange.start < position
    position -= document.getLength() if movingRightward

    unless @firstBlockInPositionRangeIsEntirelySelected(positionRange)
      [firstBlock, blocks...] = document.getBlocks()
      if blocks.length is 0
        text = firstBlock.getTextWithoutBlockBreak()
        position += 1 if movingRightward
      else
        text = firstBlock.text

      @insertTextAtPositionRange(text, position)
      return if blocks.length is 0

      document = new Trix.Document blocks
      position += text.getLength()

    @insertDocumentAtPositionRange(document, position)

  addAttributeAtPositionRange: edit "addAttributeAtPositionRange", (attribute, value, positionRange) ->
    @eachBlockAtPositionRange positionRange, (block, textRange, index) =>
      @blockList = @blockList.editObjectAtIndex index, ->
        if Trix.config.blockAttributes[attribute]
          block.addAttribute(attribute, value)
        else
          if textRange[0] is textRange[1]
            block
          else
            block.copyWithText(block.text.addAttributeAtRange(attribute, value, textRange))

  addAttribute: edit "addAttribute", (attribute, value) ->
    @eachBlock (block, index) =>
      @blockList = @blockList.editObjectAtIndex (index), ->
        block.addAttribute(attribute, value)

  removeAttributeAtPositionRange: edit "removeAttributeAtPositionRange", (attribute, positionRange) ->
    @eachBlockAtPositionRange positionRange, (block, textRange, index) =>
      if Trix.config.blockAttributes[attribute]
        @blockList = @blockList.editObjectAtIndex index, ->
          block.removeAttribute(attribute)
      else if textRange[0] isnt textRange[1]
        @blockList = @blockList.editObjectAtIndex index, ->
          block.copyWithText(block.text.removeAttributeAtRange(attribute, textRange))

  updateAttributesForAttachment: edit "updateAttributesForAttachment", (attributes, attachment) ->
    locationRange = @getLocationRangeOfAttachment(attachment)
    text = @getTextAtIndex(locationRange.index)
    @blockList = @blockList.editObjectAtIndex locationRange.index, (block) ->
      block.copyWithText(text.updateAttributesForAttachment(attributes, attachment))

  insertBlockBreakAtPositionRange: edit "insertBlockBreakAtPositionRange", (positionRange) ->
    positionRange = Trix.PositionRange.box(positionRange)
    position = positionRange.start
    location = @locationFromPosition(position)

    @removeTextAtPositionRange(positionRange)
    blocks = [new Trix.Block] if location.offset is 0
    @blockList = @blockList.insertSplittableListAtPosition(new Trix.SplittableList(blocks), position)

  applyBlockAttributeAtPositionRange: edit "applyBlockAttributeAtPositionRange", (attributeName, value, positionRange) ->
    positionRange = @expandPositionRangeToLineBreaksAndSplitBlocks(positionRange)
    if Trix.config.blockAttributes[attributeName].parentAttribute
      @convertLineBreaksToBlockBreaksInPositionRange(positionRange)
    @addAttributeAtPositionRange(attributeName, value, positionRange)

  firstBlockInPositionRangeIsEntirelySelected: (positionRange) ->
    locationRange = @locationRangeFromPositionRange(positionRange)
    if locationRange.start.offset is 0 and locationRange.start.index < locationRange.end.index
      true
    else if locationRange.start.index is locationRange.end.index
      length = @getBlockAtIndex(locationRange.start.index).getLength()
      locationRange.start.offset is 0 and locationRange.end.offset is length
    else
      false

  expandPositionRangeToLineBreaksAndSplitBlocks: (positionRange) ->
    locationRange = @locationRangeFromPositionRange(positionRange)
    start = index: locationRange.start.index, offset: locationRange.start.offset
    end = index: locationRange.end.index, offset: locationRange.end.offset

    @edit =>
      startBlock = @getBlockAtIndex(start.index)
      if (start.offset = startBlock.findLineBreakInDirectionFromPosition("backward", start.offset))?
        position = @positionFromLocation(start)
        @insertBlockBreakAtPositionRange([position, position + 1])
        end.index += 1
        end.offset -= @getBlockAtIndex(start.index).getLength()
        start.index += 1
      start.offset = 0

      if end.offset is 0 and end.index > start.index
        end.index -= 1
        end.offset = @getBlockAtIndex(end.index).getBlockBreakPosition()
      else
        endBlock = @getBlockAtIndex(end.index)
        if endBlock.text.getStringAtRange([end.offset - 1, end.offset]) is "\n"
          end.offset -= 1
        else
          end.offset = endBlock.findLineBreakInDirectionFromPosition("forward", end.offset)
        unless end.offset is endBlock.getBlockBreakPosition()
          position = @positionFromLocation(end)
          @insertBlockBreakAtPositionRange([position, position + 1])

    @positionRangeFromLocationRange(new Trix.LocationRange start, end)

  convertLineBreaksToBlockBreaksInPositionRange: (positionRange) ->
    positionRange = Trix.PositionRange.box(positionRange)
    position = positionRange.start
    string = @getStringAtPositionRange(positionRange).slice(0, -1)

    @edit =>
      string.replace /.*?\n/g, (match) =>
        position += Trix.UTF16String.fromUCS2String(match).length
        @insertBlockBreakAtPositionRange([position - 1, position])

    positionRange

  getDocumentAtPositionRange: (positionRange) ->
    range = Trix.PositionRange.box(positionRange).toArray()
    blocks = @blockList.getSplittableListInRange(range).toArray()
    new @constructor blocks

  getStringAtPositionRange: (positionRange) ->
    @getDocumentAtPositionRange(positionRange).toString()

  getBlockAtIndex: (index) ->
    @blockList.getObjectAtIndex(index)

  getBlockAtPosition: (position) ->
    {index} = @locationFromPosition(position)
    @getBlockAtIndex(index)

  getTextAtIndex: (index) ->
    @getBlockAtIndex(index)?.text

  getTextAtPosition: (position) ->
    {index} = @locationFromPosition(position)
    @getTextAtIndex(index)

  getPieceAtPosition: (position) ->
    {index, offset} = @locationFromPosition(position)
    text = @getTextAtIndex(index).getTextAtRange([offset, offset + 1])
    text.getPieces()[0]

  getLength: ->
    @blockList.getEndPosition()

  getBlocks: ->
    @blockList.toArray()

  eachBlock: (callback) ->
    @blockList.eachObject(callback)

  eachBlockAtPositionRange: (positionRange, callback) ->
    locationRange = @locationRangeFromPositionRange(positionRange)
    if locationRange.isInSingleIndex()
      block = @getBlockAtIndex(locationRange.index)
      textRange = [locationRange.start.offset, locationRange.end.offset]
      callback(block, textRange, locationRange.index)
    else
      locationRange.eachIndex (index) =>
        block = @getBlockAtIndex(index)

        textRange = switch index
          when locationRange.start.index
            [locationRange.start.offset, block.text.getLength()]
          when locationRange.end.index
            [0, locationRange.end.offset]
          else
            [0, block.text.getLength()]

        callback(block, textRange, index)

  getCommonAttributesAtPositionRange: (positionRange) ->
    positionRange = Trix.PositionRange.box(positionRange)
    if positionRange.isCollapsed()
      @getCommonAttributesAtPosition(positionRange.start)
    else
      textAttributes = []
      blockAttributes = []

      @eachBlockAtPositionRange positionRange, (block, textRange) ->
        unless textRange[0] is textRange[1]
          textAttributes.push(block.text.getCommonAttributesAtRange(textRange))
          blockAttributes.push(attributesForBlock(block))

      Trix.Hash.fromCommonAttributesOfObjects(textAttributes)
        .merge(Trix.Hash.fromCommonAttributesOfObjects(blockAttributes))
        .toObject()

  getCommonAttributesAtPosition: (position) ->
    {index, offset} = @locationFromPosition(position)
    block = @getBlockAtIndex(index)
    return {} unless block

    commonAttributes = attributesForBlock(block)
    attributes = block.text.getAttributesAtPosition(offset)
    attributesLeft = block.text.getAttributesAtPosition(offset - 1)
    inheritableAttributes = (key for key, value of Trix.config.textAttributes when value.inheritable)

    for key, value of attributesLeft
      if value is attributes[key] or key in inheritableAttributes
        commonAttributes[key] = value

    commonAttributes

  getPositionRangeOfCommonAttributeAtPosition: (attributeName, position) ->
    {index, offset} = @locationFromPosition(position)
    text = @getTextAtIndex(index)
    [left, right] = text.getExpandedRangeForAttributeAtOffset(attributeName, offset)
    locationRange = new Trix.LocationRange {index, offset: left}, {index, offset: right}
    @positionRangeFromLocationRange(locationRange)

  attributesForBlock = (block) ->
    attributes = {}
    if attributeName = block.getLastAttribute()
      attributes[attributeName] = true
    attributes

  getAttachmentById: (attachmentId) ->
    @attachments.get(attachmentId)

  getAttachmentPieces: ->
    attachmentPieces = []
    @blockList.eachObject ({text}) ->
      attachmentPieces = attachmentPieces.concat(text.getAttachmentPieces())
    attachmentPieces

  getAttachments: ->
    piece.attachment for piece in @getAttachmentPieces()

  getPositionRangeOfAttachment: (attachment) ->
    position = 0
    for {text}, index in @blockList.toArray()
      if textRange = text.getRangeOfAttachment(attachment)
        return new Trix.PositionRange position + textRange[0], position + textRange[1]
      position += text.getLength()

  getAttachmentPieceForAttachment: (attachment) ->
    return piece for piece in @getAttachmentPieces() when piece.attachment is attachment

  rangeFromLocationRange: (locationRange) ->
    leftPosition = @positionFromLocation(locationRange.start)
    rightPosition = @positionFromLocation(locationRange.end) unless locationRange.isCollapsed()
    [leftPosition, rightPosition ? leftPosition]

  locationFromPosition: (position) ->
    location = @blockList.findIndexAndOffsetAtPosition(Math.max(0, position))
    if location.index?
      location
    else
      blocks = @getBlocks()
      index: blocks.length - 1, offset: blocks[blocks.length - 1].getLength()

  positionFromLocation: (location) ->
    @blockList.findPositionAtIndexAndOffset(location.index, location.offset)

  locationRangeFromPosition: (position) ->
    new Trix.LocationRange @locationFromPosition(position)

  locationRangeFromRange: ([start, end]) ->
    startLocation = @locationFromPosition(start)
    endLocation = @locationFromPosition(end)
    new Trix.LocationRange startLocation, endLocation

  locationRangeFromPositionRange: (positionRange) ->
    return unless positionRange = Trix.PositionRange.box(positionRange)
    startLocation = @locationFromPosition(positionRange.start)
    endLocation = @locationFromPosition(positionRange.end)
    new Trix.LocationRange startLocation, endLocation

  positionRangeFromLocationRange: (locationRange) ->
    leftPosition = @positionFromLocation(locationRange.start)
    rightPosition = @positionFromLocation(locationRange.end) unless locationRange.isCollapsed()
    new Trix.PositionRange leftPosition, rightPosition

  isEqualTo: (document) ->
    @blockList.isEqualTo(document?.blockList)

  getTexts: ->
    block.text for block in @getBlocks()

  getPieces: ->
    pieces = []
    for text in @getTexts()
      pieces.push(text.getPieces()...)
    pieces

  getObjects: ->
    @getBlocks().concat(@getTexts()).concat(@getPieces())

  toSerializableDocument: ->
    blocks = []
    @blockList.eachObject (block) ->
      blocks.push(block.copyWithText(block.text.toSerializableText()))
    new @constructor blocks

  toString: ->
    @blockList.toString()

  toJSON: ->
    @blockList.toJSON()

  toConsole: ->
    JSON.stringify(JSON.parse(block.text.toConsole()) for block in @blockList.toArray())

  # Attachments collection delegate

  collectionDidAddObject: (collection, object) ->
    object.delegate = this
    @delegate?.documentDidAddAttachment(this, object)

  collectionDidRemoveObject: (collection, object) ->
    delete object.delegate
    @delegate?.documentDidRemoveAttachment(this, object)

  # Attachment delegate

  attachmentDidChangeAttributes: (attachment) ->
    @delegate?.documentDidEditAttachment(this, attachment)

  # Private

  refresh: ->
    @refreshAttachments()

  refreshAttachments: ->
    @attachments.refresh(@getAttachments())
