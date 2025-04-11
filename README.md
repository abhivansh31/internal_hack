# Credit-Bank Protocol

A decentralized credit scoring and lending protocol that evaluates creditworthiness based on on-chain activity and collateral management.

## Overview

Credit-Bank implements a sophisticated credit scoring system that determines user creditworthiness through multiple factors:

-   Payment History (40%): Evaluates timely debt repayments
-   Credit Utilization (30%): Assesses borrowed amount relative to collateral
-   Collateral Mix (20%): Rewards diversification of collateral types
-   Length of Credit History (10%): Considers duration of credit activity

## Features

-   Dynamic credit scoring (0-1000 range)
-   Multi-collateral support
-   Risk-adjusted interest rates
-   Automated credit score updates
-   Collateralization ratio monitoring
-   Flexible loan terms

## Credit Score Components

### Payment History (40%)

-   Tracks on-time, early, and late payments
-   Applies time decay to historical payments
-   Penalizes defaults and rewards consistency

### Credit Utilization (30%)

-   Measures debt-to-collateral ratio
-   Evaluates available credit usage
-   Rewards responsible borrowing patterns

### Collateral Mix (20%)

-   Encourages collateral diversification
-   Uses entropy calculation for distribution
-   Reduces liquidation risks

### Length of Credit History (10%)

-   Considers duration of lending activity
-   Weights longer credit histories positively
-   Normalized scoring system

## Smart Contract Architecture

The protocol consists of the following main components:

-   CreditScore.sol: Core credit scoring and lending logic
-   Price feeds for collateral valuation
-   ERC20 interface for token operations

## Contributions:
Anand Bansal: My part started with the ideation of the protocol that no "famous" protocol has applied credit score in lending. This was followed by discussing this idea with team mates and further evaluation of the idea. By next day I modelled all the maths required for the protocol. In banks, it's just 2-3 if statement for each evaluation part. But to make it better, I made it continous distribution instead of discrete ifs. Next day I started working on the contract itself. The biggest problem I faced that my distribution included lots of log and e^x which are not in solidity and has to use library such as ABDK and PRBMAth. Both didn't work. The main problem was loss of precision. In PRBMath e18 format , the result of 64e18 log 2 was 32e18 not 6e18. So I used a log implementation which was given on ethereum stack exchange. I used 2^x intead of e^x. Completed the contarct in around 2-3 days. The liquidity part that was done by Abhivansh. Integration was left beacuse unfortunately Abhivansh got sick. I used minimal to no AI becuase AI really suck at maths

Aryan :  My part of the project was frontend and I mainly focused on getting frontend as crisp as possible as I got to know from my friends and seniors that to win in a hackathon, project must work and frontend must be really good. And I actually focused on trying different methods using AIs and all to make myself ready to be able  to make any kind of frontend in less than 2-3 hrs. The integration and state management part was left which can only happen if the backend is integrated which we couldn't complete unfortunately because of lack of planning, becoming over ambitious, personal reasons and one member becoming sick. The frontEnd was completed on the 3 day itself but it went through various changes as backend has to be change a bit because of less amount of time left and I tried to make it as user friendly as possible. Obv I took a lot of help from AI. Got guidance from Aniruddh sir and my friend Sachin. I myself researched on how many defi protocols have made their website. Using them as references. I tried to make website look good. I first used chatgpt for frontend and I thought it was good until my Sachin told me its not. Then I completely ditched the old frontend. Made it from scratch again. Used claude, and my own debugging skills (which took most of the time btw) to get it as close to as being a professional website. Also tried git rebase -i in between and created an absolute mess (won't ever do it again in a hackathon).
