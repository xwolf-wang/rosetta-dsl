package com.regnosys.rosetta.validation

import com.google.inject.Inject
import com.regnosys.rosetta.RosettaExtensions
import com.regnosys.rosetta.rosetta.BlueprintAnd
import com.regnosys.rosetta.rosetta.BlueprintCustomNode
import com.regnosys.rosetta.rosetta.BlueprintDataJoin
import com.regnosys.rosetta.rosetta.BlueprintExtract
import com.regnosys.rosetta.rosetta.BlueprintFilter
import com.regnosys.rosetta.rosetta.BlueprintGroup
import com.regnosys.rosetta.rosetta.BlueprintLookup
import com.regnosys.rosetta.rosetta.BlueprintMerge
import com.regnosys.rosetta.rosetta.BlueprintNode
import com.regnosys.rosetta.rosetta.BlueprintNodeExp
import com.regnosys.rosetta.rosetta.BlueprintOneOf
import com.regnosys.rosetta.rosetta.BlueprintReduce
import com.regnosys.rosetta.rosetta.BlueprintRef
import com.regnosys.rosetta.rosetta.BlueprintReturn
import com.regnosys.rosetta.rosetta.BlueprintSource
import com.regnosys.rosetta.rosetta.BlueprintValidate
import com.regnosys.rosetta.rosetta.RosettaAlias
import com.regnosys.rosetta.rosetta.RosettaBinaryOperation
import com.regnosys.rosetta.rosetta.RosettaCallable
import com.regnosys.rosetta.rosetta.RosettaCallableCall
import com.regnosys.rosetta.rosetta.RosettaConditionalExpression
import com.regnosys.rosetta.rosetta.RosettaCountOperation
import com.regnosys.rosetta.rosetta.RosettaExistsExpression
import com.regnosys.rosetta.rosetta.RosettaExpression
import com.regnosys.rosetta.rosetta.RosettaFactory
import com.regnosys.rosetta.rosetta.RosettaFeatureCall
import com.regnosys.rosetta.rosetta.RosettaGroupByFeatureCall
import com.regnosys.rosetta.rosetta.RosettaLiteral
import com.regnosys.rosetta.rosetta.RosettaType
import com.regnosys.rosetta.rosetta.RosettaTyped
import com.regnosys.rosetta.rosetta.impl.RosettaFeatureImpl
import com.regnosys.rosetta.rosetta.simple.Attribute
import com.regnosys.rosetta.rosetta.simple.Data
import com.regnosys.rosetta.types.RBuiltinType
import com.regnosys.rosetta.types.RosettaTypeCompatibility
import com.regnosys.rosetta.types.RosettaTypeProvider
import java.util.ArrayList
import java.util.List
import org.eclipse.emf.ecore.EObject
import org.eclipse.emf.ecore.EStructuralFeature

import static com.regnosys.rosetta.rosetta.RosettaPackage.Literals.*
import com.regnosys.rosetta.rosetta.RosettaContainsExpression
import com.regnosys.rosetta.rosetta.RosettaAbsentExpression
import com.regnosys.rosetta.rosetta.RosettaDisjointExpression
import com.regnosys.rosetta.rosetta.RosettaEnumValueReference
import com.regnosys.rosetta.rosetta.RosettaParenthesisCalcExpression
import com.regnosys.rosetta.rosetta.RosettaCallableWithArgsCall
import com.regnosys.rosetta.rosetta.RosettaEnumeration
import com.regnosys.rosetta.types.RosettaOperators
import java.util.Set
import java.util.HashSet
import com.regnosys.rosetta.validation.TypedBPNode.BPCardinality
import com.regnosys.rosetta.generator.java.function.CardinalityProvider
import com.regnosys.rosetta.rosetta.simple.Function

class RosettaBlueprintTypeResolver {
	
	@Inject extension RosettaTypeProvider
	@Inject extension RosettaTypeCompatibility
	@Inject extension RosettaExtensions
	@Inject extension RosettaOperators
	@Inject CardinalityProvider cardinality
	
	static class BlueprintTypeException extends Exception {
		new(String string) {
			super(string);
		}
		
	}

	def TypedBPNode buildTypeGraph(BlueprintNodeExp nodeExp, RosettaType output) {
		val prevNode = new TypedBPNode // a hypothetical node before this BP
		val nextNode = new TypedBPNode // a hypothetical node after this BP
		nextNode.input.type = output

		val result = new TypedBPNode
		try {
			result.next = bindTypes(nodeExp, prevNode, nextNode, new HashSet)
		}
		catch (BlueprintTypeException ex) {
			throw new BlueprintUnresolvedTypeException(ex.message,nodeExp, BLUEPRINT_NODE_EXP__NODE, RosettaIssueCodes.TYPE_ERROR)
		}
		result.input = prevNode.output
		result.inputKey = prevNode.outputKey
		result.output = nextNode.input
		result.outputKey = nextNode.inputKey
		return result
	}

	def TypedBPNode bindTypes(BlueprintNodeExp nodeExp, TypedBPNode parentNode, TypedBPNode outputNode, Set<BlueprintNode> visited) {
		val typedNode = new TypedBPNode
		typedNode.node = nodeExp.node
		typedNode.input = parentNode.output
		typedNode.inputKey = parentNode.outputKey

		val nodeFixedTypes = computeExpected(nodeExp)
		link(typedNode, visited)
		bindFixedTypes(typedNode, nodeFixedTypes, nodeExp.node)

		// check outputs
		if (nodeExp.next !== null) {
			typedNode.next = nodeExp.next.bindTypes(typedNode, outputNode, visited)
		} else {
			if (!typedNode.output.isAssignableTo(outputNode.input)) {
				BlueprintUnresolvedTypeException.error('''output type of node «typedNode.output.either» does not match required type of «outputNode.input.either»''', nodeExp.node,
							BLUEPRINT_NODE__NAME, RosettaIssueCodes.TYPE_ERROR)
			}
			// check the terminal types match the expected
			if (typedNode.output.type !== null && outputNode.input.type !== null) {
				println("fish")
			} else if (outputNode.input.type !== null) {
				outputNode.input.setGenericName("Object")
			/*error('''output type of «typedNode.output.getEither» is not assignable to expected outputType «outputNode.input.type.name» of blueprint''', 
			 nodeExp.node, BLUEPRINT_NODE__OUTPUT, RosettaIssueCodes.TYPE_ERROR)*/
			} else {
				outputNode.input.type = typedNode.output.type
				outputNode.input.genericName = typedNode.output.genericName
			}

			outputNode.inputKey = typedNode.outputKey;
		}
		typedNode
	}

	/*Get the types that are fixed by the rosetta expressions etc of these nodes
	 * e.g. for an extract node the input and output types are fixed by the rosettaExpression type
	 */
	def TypedBPNode computeExpected(BlueprintNodeExp nodeExp) {
		val node = nodeExp.node
		val result = new TypedBPNode
		// get the input type for this node
		switch (node) {
			BlueprintMerge: {
				result.output.type = node.output
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintExtract: {
				// extract defines both the input and output types
				result.input.type = getInput(node.call)
				// and the output type comes from the expression
				result.output.type = getOutput(node.call)
				result.cardinality.set(0, if (cardinality.isMulti(node.call)) BPCardinality.EXPAND else BPCardinality.UNCHANGED)
			}
			BlueprintReturn: {
				result.input.type = null
				// and the output type comes from the expression
				result.output.type = getOutput(node.expression)
				result.cardinality.set(0, if(cardinality.isMulti(node.expression)) BPCardinality.EXPAND else BPCardinality.UNCHANGED)
			}
			BlueprintRef: {
				result.output.type = node.output
			}
			BlueprintValidate: {
				result.input.type = node.input
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintFilter: {
				if(node.filter!==null) {
					result.input.type = getInput(node.filter)
				}
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintGroup: {
				result.input.type = getInput(node.key as RosettaFeatureCall)
				result.outputKey.type = getOutput(node.key as RosettaFeatureCall)
				//Cardinality is a difficult concept if you go changing the keys
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintDataJoin: {
				result.output.type = getInput(node.key as RosettaFeatureCall)
				val in1 = new TypedBPNode
				val in2 = new TypedBPNode
				in1.output.type = getInput(node.key as RosettaFeatureCall)
				in2.output.type = getInput(node.foreign)
				val unifiedInput = new TypedBPNode
				getUnionType(#[in1, in2, new TypedBPNode], unifiedInput)
				//Unless we implement proper type unions (e.g. MyClass1 OR MyClass2) the input type of a data join is always object
				//unifiedInput.output.setGenericName("Object")
				
				result.input.type = unifiedInput.output.type
				result.input.genericName = unifiedInput.output.genericName
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintSource: {
				result.output.type = node.output
				result.outputKey.type = node.outputKey
				result.input.genericName = "Void"
				result.inputKey.type = node.outputKey
				//not sure about this cardinality but this node type is unused
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintCustomNode: {
				result.input.type = node.input
				result.output.type = node.output
				result.inputKey.type = node.inputKey
				result.outputKey.type = node.outputKey
				//Cardinality depends on the implementation - but it isn't used
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintLookup : {
				result.output.type = node.output
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintAnd: {
				result.cardinality.set(0, BPCardinality.EXPAND)
			}
			BlueprintOneOf: {
				result.cardinality.set(0, BPCardinality.UNCHANGED)
			}
			BlueprintReduce: {
				if (node.expression!==null) {
					result.input.type = getInput(node.expression)
				}
				result.cardinality.set(0, BPCardinality.REDUCE)
			}
			default: {
				throw new UnsupportedOperationException("Trying to compute inputs of unknown node type " + node.class)
			}
		}
		result
	}

	//link the object refs forward through types that are unchanged by this type of node
	def void link(TypedBPNode tNode, Set<BlueprintNode> visited) {
		val node = tNode.node
		/*if (visited.contains(node)) {
			return
		}*/
		visited.add(node)
		switch (node) {
			BlueprintMerge: {
				tNode.outputKey = tNode.inputKey
			}
			BlueprintExtract, BlueprintReturn: {
				// extract doesn't change the key
				tNode.outputKey = tNode.inputKey
			}
			BlueprintLookup: {
				tNode.outputKey = tNode.inputKey
			}
			BlueprintAnd: {

				// if all the inner nodes are producing the same output then the output of the and node is that output
				var allPassThroughInput = true
				var allPassThroughKey = true
				val outputs = newArrayList
				val inputs = newArrayList
				for (child : node.bps) {
					val bpIn = new TypedBPNode
					val bpOut = new TypedBPNode
					bpIn.output = tNode.input
					bpIn.outputKey = tNode.inputKey
					tNode.andNodes.add(bindTypes(child, bpIn, bpOut, visited))

					if (bpIn.output !== bpOut.input) {
						allPassThroughInput = false
					}
					if (bpIn.outputKey !== bpOut.inputKey) {
						allPassThroughInput = false
					}
					outputs.add(bpOut.invert)
					inputs.add(bpIn.invert)
				}
				if (allPassThroughInput) {
					tNode.output = tNode.input
				}
				if (allPassThroughKey) {
					tNode.outputKey = tNode.inputKey
				}

				getUnionType(outputs, tNode)
				getBaseType(inputs, tNode, node)
			}
			BlueprintFilter: {
				tNode.output = tNode.input
				tNode.outputKey = tNode.inputKey
				if (node.filterBP!==null) {
					val bpIn = new TypedBPNode
					val bpOut = new TypedBPNode
					bpIn.output=tNode.input;
					bpIn.inputKey = tNode.inputKey;
					bpOut.input.genericName  ="Boolean"
					bpOut.inputKey = tNode.inputKey
					bpIn.outputKey = tNode.inputKey
					try {
						bindTypes(node.filterBP.blueprint.nodes, bpIn, bpOut, visited)
					}
					catch (BlueprintUnresolvedTypeException e) {
					//we found an that the types don't match further down the stack - we want to report it as an error with this call
						BlueprintUnresolvedTypeException.error(e.message,
						node.filterBP, BLUEPRINT_REF__BLUEPRINT, e.code)
					}
					tNode.andNodes.add(TypedBPNode.combine(bpOut, bpIn).invert)
				}
			}
			BlueprintOneOf: {
				var allPassThroughInput = true
				var allPassThroughKey = true
				val outputs = newArrayList
				val inputs = newArrayList
				val allThens = new ArrayList(node.bps.map[thenNode])
				if (node.elseNode!==null) allThens.add(node.elseNode)
				for (var i=0;i<allThens.size;i++) {
					val bpIn = new TypedBPNode
					val bpOut = new TypedBPNode
					bpIn.output = tNode.input
					bpIn.outputKey = tNode.inputKey
					tNode.andNodes.add(bindTypes(allThens.get(i), bpIn, bpOut, visited))
					if (i<node.bps.size) {
						tNode.ifNodes.add(bindTypes(node.bps.get(i).ifNode, bpIn, new TypedBPNode, visited))//the output type of the if's can be anything (null or boolean false==false)
					}
					if (bpIn.output !== bpOut.input) {
						allPassThroughInput = false
					}
					if (bpIn.outputKey !== bpOut.inputKey) {
						allPassThroughInput = false
					}
					outputs.add(bpOut.invert)
					inputs.add(bpIn.invert)
				}
				if (allPassThroughInput) {
					tNode.output = tNode.input
				}
				if (allPassThroughKey) {
					tNode.outputKey = tNode.inputKey
				}

				getUnionType(outputs, tNode)
				getBaseType(inputs, tNode, node)
			}
			BlueprintRef: {
				val bpIn = new TypedBPNode
				val bpOut = new TypedBPNode
				bpIn.output = tNode.input
				bpIn.outputKey = tNode.inputKey
				bpOut.input = tNode.output
				bpOut.inputKey = tNode.outputKey

				try {
					val child = bindTypes(node.blueprint.nodes, bpIn, bpOut, visited)
					tNode.cardinality = child.cardinality
				}
				catch (BlueprintUnresolvedTypeException e) {
					//we found an that the types don't match further down the stack - we want to report it as an error with this call
					BlueprintUnresolvedTypeException.error(e.message,
					node, BLUEPRINT_REF__BLUEPRINT, e.code)
				}
				tNode.output = bpOut.input
				tNode.outputKey = bpOut.inputKey
			}
			BlueprintValidate: {
				tNode.output = tNode.input
				tNode.outputKey = tNode.inputKey
			}
			BlueprintReduce: {
				tNode.output = tNode.input
				tNode.outputKey = tNode.inputKey
				if (node.reduceBP!==null) {
					val bpIn = new TypedBPNode
					val bpOut = new TypedBPNode
					bpIn.output=tNode.input;
					bpIn.outputKey = tNode.input
					bpIn.inputKey = tNode.inputKey;
					bpOut.input.genericName  ="Comparable"
					bpOut.inputKey = tNode.input
					//check the called node meets type expectations
					try {
						bindTypes(node.reduceBP.blueprint.nodes, bpIn, bpOut, visited)
					} catch (BlueprintUnresolvedTypeException e) {
						// we found an that the types don't match further down the stack - we want to report it as an error with this call
						BlueprintUnresolvedTypeException.error(e.message, node.reduceBP, BLUEPRINT_REF__BLUEPRINT, e.code)
					}
					tNode.andNodes.add(TypedBPNode.combine(bpOut, bpIn).invert)
				}
			}
			BlueprintGroup: {
				tNode.output = tNode.input
			}
			BlueprintDataJoin: {
				tNode.outputKey = tNode.inputKey
			}
			BlueprintSource: {
				// binds everything
			}
			BlueprintCustomNode: {
				// Custom nodes have to bind everything
			}
			default: {
				throw new UnsupportedOperationException("Trying to compute linkages of unknown node type " + node.class)
			}
		}
	}

/**
 * Computes the tightest possible type for the output types of a list of nodes
 * and sets the output node of tNode to that type
 */
	private def getUnionType(List<TypedBPNode> types, TypedBPNode tNode) {
		val outputTypes = types.map[output.type]
		val count = outputTypes.stream.distinct.count
		if (count == 1) {
			tNode.output.type = outputTypes.get(0)
			tNode.output.genericName = types.get(0).output.genericName
		} else if (outputTypes.forall[it !== null && (it.name == "int" || it.name == "number")])
			tNode.output.setGenericName("Number")
		/*				val end= getRType(typedNode.output.type)
		 * 		val expectedOutput= getRType(outputNode.input.type)
		 if (!end.isUseableAs(expectedOutput)) {*/
		else
			tNode.output.setGenericName("Object") // if there is more then one type just go for object
		val keyTypes = types.map[outputKey.type]
		val countKey = keyTypes.stream.distinct.count
		if (countKey == 1)
			tNode.outputKey.type = keyTypes.get(0)
		else if (keyTypes.forall[it.name == "int" || it.name == "number"])
			tNode.outputKey.setGenericName("Number")
		/*				val end= getRType(typedNode.output.type)
		 * 		val expectedOutput= getRType(outputNode.input.type)
		 if (!end.isUseableAs(expectedOutput)) {*/
		else
			tNode.outputKey.setGenericName("Object") // if there is more then one type just go for object
	}

	def getBaseType(List<TypedBPNode> types, TypedBPNode tNode, BlueprintNode node) {
		val inputTypes = types.map[input.type]
		val count = inputTypes.stream.distinct.count
		if (count == 1)
			tNode.input.type = inputTypes.get(0)
		else if (inputTypes.forall[it.name == "int" || it.name == "number"])
			tNode.input.setGenericName("Integer")
		else
			BlueprintUnresolvedTypeException.error('''input types of andNode «inputTypes.map[name]» are not compatible''', node, BLUEPRINT_NODE__INPUT,
				RosettaIssueCodes.TYPE_ERROR)

		// now for keys
		val inputKeyTypes = types.map[inputKey.type]
		val countKey = inputKeyTypes.stream.distinct.count
		if (countKey == 1)
			tNode.inputKey.type = inputKeyTypes.get(0)
		else if (inputKeyTypes.forall[it.name == "int" || it.name == "number"])
			tNode.inputKey.setGenericName("Integer")
		else
			BlueprintUnresolvedTypeException.error('''inputKey types of andNode «inputKeyTypes.map[name]» are not compatible''', node,
				BLUEPRINT_NODE__INPUT_KEY, RosettaIssueCodes.TYPE_ERROR)
	}

	def bindFixedTypes(TypedBPNode node, TypedBPNode expected, BlueprintNode bpNode) {
		bindInType(node.input, expected.input, bpNode, "Input")
		bindInType(node.inputKey, expected.inputKey, bpNode, "InputKey")
		bindOutType(node.output, expected.output, bpNode, "Output")
		bindOutType(node.outputKey, expected.outputKey, bpNode, "OutputKey")
		node.cardinality.set(0,expected.cardinality.get(0))
	}

	def bindInType(BindableType nodeType, BindableType expected, BlueprintNode node, String fieldName) {
		if (expected.isBound) {
			if (!nodeType.isBound) {
				// the expected input is known and the actual is unbound - bind it
				nodeType.type = expected.type
				nodeType.genericName = expected.genericName
			} else if (isAssignableTo(expected, nodeType)) {
				nodeType.type = expected.type
				nodeType.genericName = expected.genericName
			}
			else if (!isAssignableTo(expected, nodeType)){
				BlueprintUnresolvedTypeException.error('''«fieldName» type of «expected.either» is not assignable from type «nodeType.either» of previous node «node.name»''',
					node, BLUEPRINT_NODE__INPUT, RosettaIssueCodes.TYPE_ERROR)
			}
		}
	}

	def bindOutType(BindableType nodeType, BindableType expected, BlueprintNode node, String fieldName) {
		if (expected.isBound) {
			if (!nodeType.isBound) {
				// the expected input is know and the actual is unbound - bind it
				nodeType.type = expected.type
				nodeType.genericName = expected.genericName
			} else {
				// both ends are known, check they are compatible
				val inType = getRType(nodeType)
				val exType = getRType(expected)
				if (!inType.isUseableAs(exType)) {
					BlueprintUnresolvedTypeException.error('''«fieldName» type of «expected.type.name» is not assignable to «fieldName» type «nodeType.type.name» of next node «node.name»''',
						node, BLUEPRINT_NODE__INPUT, RosettaIssueCodes.TYPE_ERROR)
				} else {
					nodeType.type = expected.type
				}
			}
		}
	}

	def getRType(BindableType t) {
		if (t.type !== null) {
			return getRType(t.type)
		}
		switch (t.genericName) {
			case "Number",
			case "number": {
				return RBuiltinType.NUMBER
			}
			default: {
				return RBuiltinType.MISSING
			}
		}
	}
//
//	def dispatch RosettaType getInput(RosettaLiteral expr) {
//		return expr.type
//	}

	def dispatch RosettaType getInput(RosettaExpression expr) {
		val rType = expr.RType
		//TODO this need to be transformed somehow into a nice grammar error
		throw new UnsupportedOperationException(
			"Unexpected input expression "  + expr.class + "... " + rType)
	}
	
	def dispatch RosettaType getInput(RosettaContainsExpression expr) {
		return getInput(expr.container)
	}
	
	def dispatch RosettaType getInput(RosettaLiteral literal) {
		null
	}
	
	def dispatch RosettaType getInput(RosettaCountOperation expr) {
		return getInput(expr.argument);
	}

	def dispatch RosettaType getInput(RosettaBinaryOperation expr) {
		val t1 = getInput(expr.left)
		val t2 = getInput(expr.right)
		if (t1!==null && t2!==null && t1!=t2) {
			throw new BlueprintTypeException('''Input types must be the same but were «t1.name» and «t2.name»''');
		}
		return t1
	}

	def dispatch RosettaType getInput(RosettaCallableCall expr) {
		return getInput(expr.callable)
	}

	def dispatch RosettaType getInput(RosettaFeatureCall call) {
		return getInput(call.receiver)
	}

	def dispatch RosettaType getInput(RosettaCallable callable) {
		switch (callable) {
			Data: {
				return callable
			}
			RosettaAlias: {
				return getInput(callable.expression)
			}
			RosettaEnumeration :{
				//evaluating a enum constant does not require an input type
				return null
			}
		}
		throw new UnsupportedOperationException(
			"Unexpected input parsing rosetta callable " + callable.class.simpleName)
	}
	
	def dispatch RosettaType getInput(RosettaConditionalExpression call) {
		return getInput(call.^if);		
	}
	
	def dispatch RosettaType getInput(RosettaGroupByFeatureCall call) {
		return getInput(call.call);		
	}
	
	def dispatch RosettaType getInput(RosettaExistsExpression expr) {
		return getInput(expr.argument)
	}
	
	def dispatch RosettaType getInput(RosettaAbsentExpression expr) {
		return getInput(expr.argument)
	}
	
	def dispatch RosettaType getInput(RosettaDisjointExpression expr) {
		return getInput(expr.container)//TODO check RHS has matching scope? or is that checked elsewhere
	}
	
	def dispatch RosettaType getInput(RosettaEnumValueReference expr) {
		return null
	}
	
	def dispatch RosettaType getInput(RosettaParenthesisCalcExpression expr) {
		return getInput(expr.expression)
	}
	
	def dispatch RosettaType getInput(RosettaCallableWithArgsCall expr) {
		if (expr.args.size==0) return null
		val inputs = expr.args.map[getInput]
		if (inputs.toSet.size>1)
			throw new BlueprintTypeException('''Input types must be the same but were «inputs.map[name]»''');
		return inputs.get(0)
	}
	def dispatch RosettaType getInput(Void typed) {
		return null
	}

	def dispatch RosettaType getOutput(RosettaExpression expr) {
		var st = RosettaFactory.eINSTANCE.createRosettaBasicType
		st.name = expr.getRType.name
		return st
	}
	
	//def dispatch RosettaType getOutput(RosettaCallable)

	def dispatch RosettaType getOutput(RosettaAlias expr) {
		getOutput(expr.expression)
	}

	def dispatch RosettaType getOutput(RosettaCallableCall callable) {
		return callable.callable.output
	}
	
	def dispatch RosettaType getOutput(Function func) {
		return func.output.type
	}
	
	def dispatch RosettaType getOutput(RosettaCallableWithArgsCall callable) {
		return callable.callable.output
	}
	
	def dispatch RosettaType getOutput(RosettaBinaryOperation binOp) {
		var st = RosettaFactory.eINSTANCE.createRosettaBasicType
		st.name = binOp.getRType.name
		return st
	}
	
	def dispatch RosettaType getOutput(RosettaCountOperation countOp) {
		var st = RosettaFactory.eINSTANCE.createRosettaBasicType
		st.name = countOp.getRType.name
		return st
	}

	def dispatch RosettaType getOutput(RosettaExistsExpression exists) {
		var st = RosettaFactory.eINSTANCE.createRosettaBasicType
		st.name = exists.getRType.name
		return st
	}
	
	def dispatch RosettaType getOutput(RosettaConditionalExpression cond) {
		return cond.ifthen.getOutput
		//TODO the if case and the else case must return the same type - or is this checked elsewhere?
	}
	
	def dispatch RosettaType getOutput(RosettaContainsExpression cond) {
		var st = RosettaFactory.eINSTANCE.createRosettaBasicType
		st.name = cond.getRType.name
		return st
	}
	
	def dispatch RosettaType getOutput(RosettaGroupByFeatureCall groupCall) {
		groupCall.call.output
	}

	def dispatch RosettaType getOutput(RosettaLiteral literal) {
		var st = RosettaFactory.eINSTANCE.createRosettaBasicType
		st.name = literal.getRType.name
		return st
	}

	def dispatch RosettaType getOutput(RosettaTyped typed) {
		return typed.type
	}

	def dispatch RosettaType getOutput(RosettaFeatureCall call) {
		val feature = call.feature
		switch (feature) {
			Attribute: {
				return feature.type
			}
			RosettaFeatureImpl: {
				// This is the result when the expression hasn't bound to an attribute properly
				val wrongType = getLastType(call.receiver)
				BlueprintUnresolvedTypeException.error('''attempted to reference unknown field of «wrongType»''', call, ROSETTA_FEATURE_CALL__FEATURE,
					RosettaIssueCodes.MISSING_ATTRIBUTE)
				return null
			}
		}
		throw new UnsupportedOperationException("Unexpected input parsing rosetta feature call feature of type " +
			feature.class.simpleName)
	}
	def dispatch RosettaType getOutput(Void typed) {
		return null
	}

	def getLastType(RosettaExpression expression) {
		switch (expression) {
			RosettaFeatureCall: {
				getOutput(expression).name
			}
			RosettaCallableCall: {
				""
			}
		}
	}
	
	static class BlueprintUnresolvedTypeException extends Exception {
		EObject source
		EStructuralFeature feature
		String code
		String[] issueData
		
		new(String message, EObject source, EStructuralFeature feature, String code, String... issueData) {
			super(message)
			this.source = source
			this.feature = feature
			this.code = code
			this.issueData = issueData
		}
		
		static def BlueprintUnresolvedTypeException error (String message, EObject source, EStructuralFeature feature, String code, String... issueData) {
			throw new BlueprintUnresolvedTypeException(message, source, feature, code, issueData)
		}
		
		def getEStructuralFeature() {
			feature
		}
	
		def getCode() {
			code
		}
		
		def getIssueData() {
			issueData
		}
		
		def getSource(){
			source
		}
	}

	/**
	 * returns true if a is a subclass of b
	 * i.e. this would be valid
	 * Type1 a;
	 * Type2 b;
	 * b = a
	 * */
	def isAssignableTo(BindableType type1, BindableType type2) {
		if (!type1.bound || !type2.bound) return true;
		if (type2.genericName=="number") {
			return type1.genericName=="number" || type1.genericName=="int"
		}
		else if (type1.genericName=="Object") {
			return true
		}
		else if (type2.genericName=="Comparable") {
			return type1.type?.RType?.isSelfComparable
		}
		else if (type2.genericName!==null) {
			return type2.genericName==type1.either
		}
		else if (type2.type instanceof Data && type1.type instanceof Data) {
			val class2 = type2.type as Data
			val class1 = type1.type as Data
			return class1.allSuperTypes.contains(class2);
		}
		else return type1.type == type2.type;
	}
}